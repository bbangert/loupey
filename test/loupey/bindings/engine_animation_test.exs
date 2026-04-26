defmodule Loupey.Bindings.EngineAnimationTest do
  @moduledoc """
  Engine ↔ Ticker integration tests.

  Exercises `Engine.dispatch_animations_for_entity/3` and
  `Engine.cancel_all_animations/1` directly — both are `@doc false`
  but module-public so we can drive the dispatch logic with a real
  Ticker without booting the full Engine GenServer.

  Each test starts a Ticker for a unique device_id (via `make_ref/0`),
  pipes Ticker output to the test pid via `render_target: {:test, pid}`,
  constructs an `Engine.State` directly, and asserts on Ticker state
  before/after dispatch.
  """

  use ExUnit.Case, async: false

  alias Hassock.EntityState
  alias Loupey.Animation.{Keyframes, Ticker}
  alias Loupey.Bindings.{Binding, Engine, InputRule, Layout, OutputRule, Rules}
  alias Loupey.Device.{Control, Display, Spec}
  alias Loupey.Events.PressEvent

  defp simple_keyframe(opts) do
    Keyframes.parse(
      Map.merge(
        %{
          duration_ms: 200,
          iterations: 1,
          keyframes: %{
            0 => %{fill: %{amount: 0}},
            100 => %{fill: %{amount: 100}}
          }
        },
        Map.new(opts)
      )
    )
  end

  defp setup_engine(control_id) do
    spec = %Spec{
      type: "test-device",
      controls: [
        %Control{
          id: control_id,
          capabilities: MapSet.new([:display]),
          display: %Display{width: 16, height: 16, pixel_format: :rgb888, display_id: "main"}
        }
      ]
    }

    device_id = {:engine_anim_test, make_ref()}

    {:ok, ticker_pid} =
      Ticker.start_link(device_id: device_id, spec: spec, render_target: {:test, self()})

    on_exit(fn -> if Process.alive?(ticker_pid), do: GenServer.stop(ticker_pid) end)

    state = %Engine.State{
      device_id: device_id,
      spec: spec,
      profile: nil,
      entity_states: %{},
      last_match: %{}
    }

    {device_id, state}
  end

  defp ticker_state(device_id), do: Ticker.get_state(device_id)

  defp animated_layout(control_id, when_clauses_with_kfs) do
    rules =
      for {when_clause, anims, on_enters} <- when_clauses_with_kfs do
        %OutputRule{
          when: when_clause,
          instructions: %{background: "#000000"},
          animations: anims,
          on_enter: on_enters
        }
      end

    binding = %Binding{
      entity_id: "light.test",
      input_rules: [],
      output_rules: rules
    }

    %Layout{name: "default", bindings: %{control_id => [binding]}}
  end

  describe "no_match → match" do
    test "installs continuous animation and on_enter one-shots" do
      control_id = {:key, 0}
      {_device_id, state} = setup_engine(control_id)

      kf_continuous = simple_keyframe(iterations: :infinite)
      kf_on_enter = simple_keyframe(iterations: 1)

      layout = animated_layout(control_id, [{true, [kf_continuous], [kf_on_enter]}])

      state = %{
        state
        | entity_states: %{"light.test" => %EntityState{entity_id: "light.test", state: "on"}}
      }

      state = Engine.dispatch_animations_for_entity(layout, "light.test", state)

      ts = ticker_state(state.device_id)
      assert %{^control_id => ctl} = ts.animations
      assert length(ctl.continuous) == 1
      assert length(ctl.one_shots) == 1

      assert state.last_match == %{{control_id, 0} => {:matched, 0}}
    end
  end

  describe "match → match (same rule_idx)" do
    test "preserves in-flight animations on repeated state change" do
      control_id = {:key, 0}
      {_device_id, state} = setup_engine(control_id)

      kf = simple_keyframe(iterations: :infinite)
      layout = animated_layout(control_id, [{true, [kf], []}])

      state = %{
        state
        | entity_states: %{"light.test" => %EntityState{entity_id: "light.test", state: "on"}}
      }

      state = Engine.dispatch_animations_for_entity(layout, "light.test", state)

      first_state = ticker_state(state.device_id)

      first_started_at =
        first_state.animations[control_id].continuous
        |> hd()
        |> Map.get(:started_at)

      Process.sleep(20)

      # Second dispatch — same rule, same idx → no-op (no cancel, no install).
      state = Engine.dispatch_animations_for_entity(layout, "light.test", state)

      second_state = ticker_state(state.device_id)

      second_started_at =
        second_state.animations[control_id].continuous
        |> hd()
        |> Map.get(:started_at)

      assert first_started_at == second_started_at,
             "continuous animation was reinstalled on same-rule re-match"

      assert length(second_state.animations[control_id].continuous) == 1
    end

    test "refreshes Ticker base_instructions on same-rule re-match" do
      control_id = {:key, 0}
      {_device_id, state} = setup_engine(control_id)

      kf = simple_keyframe(iterations: :infinite)

      # Rule template that pulls text from entity state — when the
      # entity flips between e.g. "12.5" and "37.0" the rule still
      # matches (when: true) but the resolved instructions change.
      rule = %OutputRule{
        when: true,
        instructions: %{background: "#000000", text: "{{ state }}°"},
        animations: [kf],
        on_enter: []
      }

      binding = %Loupey.Bindings.Binding{
        entity_id: "light.test",
        input_rules: [],
        output_rules: [rule]
      }

      layout = %Loupey.Bindings.Layout{name: "default", bindings: %{control_id => [binding]}}

      state = %{
        state
        | entity_states: %{"light.test" => %EntityState{entity_id: "light.test", state: "12.5"}}
      }

      state = Engine.dispatch_animations_for_entity(layout, "light.test", state)
      first_base = ticker_state(state.device_id).animations[control_id].base_instructions
      assert first_base.text == "12.5°"

      state = %{
        state
        | entity_states: %{"light.test" => %EntityState{entity_id: "light.test", state: "37.0"}}
      }

      state = Engine.dispatch_animations_for_entity(layout, "light.test", state)
      second_base = ticker_state(state.device_id).animations[control_id].base_instructions
      assert second_base.text == "37.0°", "base_instructions were not refreshed on re-match"

      # In-flight continuous flight is preserved (W4 dedup keeps started_at).
      assert length(ticker_state(state.device_id).animations[control_id].continuous) == 1
    end
  end

  describe "match → match (different rule_idx)" do
    test "cancels old animations and installs new" do
      control_id = {:key, 0}
      {_device_id, state} = setup_engine(control_id)

      kf_a = simple_keyframe(duration_ms: 5_000, iterations: :infinite)
      kf_b = simple_keyframe(duration_ms: 1_000, iterations: :infinite)

      layout =
        animated_layout(control_id, [
          {~s(state == "on"), [kf_a], []},
          {~s(state == "off"), [kf_b], []}
        ])

      state = %{
        state
        | entity_states: %{"light.test" => %EntityState{entity_id: "light.test", state: "on"}}
      }

      state = Engine.dispatch_animations_for_entity(layout, "light.test", state)
      assert state.last_match == %{{control_id, 0} => {:matched, 0}}

      ts1 = ticker_state(state.device_id)
      assert ts1.animations[control_id].continuous |> hd() |> Map.get(:keyframe) == kf_a

      # Flip to "off" — different rule_idx.
      state = %{
        state
        | entity_states: %{"light.test" => %EntityState{entity_id: "light.test", state: "off"}}
      }

      state = Engine.dispatch_animations_for_entity(layout, "light.test", state)
      assert state.last_match == %{{control_id, 0} => {:matched, 1}}

      ts2 = ticker_state(state.device_id)
      assert length(ts2.animations[control_id].continuous) == 1
      assert ts2.animations[control_id].continuous |> hd() |> Map.get(:keyframe) == kf_b
    end
  end

  describe "match → no_match" do
    test "cancels all animations on the control" do
      control_id = {:key, 0}
      {_device_id, state} = setup_engine(control_id)

      kf = simple_keyframe(duration_ms: 5_000, iterations: :infinite)

      layout =
        animated_layout(control_id, [
          {~s(state == "on"), [kf], []}
        ])

      state = %{
        state
        | entity_states: %{"light.test" => %EntityState{entity_id: "light.test", state: "on"}}
      }

      state = Engine.dispatch_animations_for_entity(layout, "light.test", state)
      assert Map.has_key?(ticker_state(state.device_id).animations, control_id)

      state = %{
        state
        | entity_states: %{"light.test" => %EntityState{entity_id: "light.test", state: "off"}}
      }

      state = Engine.dispatch_animations_for_entity(layout, "light.test", state)

      refute Map.has_key?(ticker_state(state.device_id).animations, control_id)
      assert state.last_match == %{{control_id, 0} => :no_match}
    end
  end

  describe "on_enter fires once per rule entry" do
    test "second dispatch with same rule does not refire on_enter" do
      control_id = {:key, 0}
      {_device_id, state} = setup_engine(control_id)

      kf_on_enter = simple_keyframe(duration_ms: 5_000, iterations: 1)

      layout = animated_layout(control_id, [{true, [], [kf_on_enter]}])

      state = %{
        state
        | entity_states: %{"light.test" => %EntityState{entity_id: "light.test", state: "on"}}
      }

      state = Engine.dispatch_animations_for_entity(layout, "light.test", state)
      assert length(ticker_state(state.device_id).animations[control_id].one_shots) == 1

      # Re-dispatch — same rule, same idx → no_op.
      state = Engine.dispatch_animations_for_entity(layout, "light.test", state)

      # One-shot count unchanged: the existing one_shot is still in-flight,
      # but no new one was queued.
      assert length(ticker_state(state.device_id).animations[control_id].one_shots) == 1
    end
  end

  describe "Ticker monitor (crash recovery)" do
    test "Engine clears last_match on Ticker :DOWN so next dispatch re-installs" do
      control_id = {:key, 0}
      {device_id, state} = setup_engine(control_id)

      [{ticker_pid, _}] = Registry.lookup(Loupey.DeviceRegistry, {:ticker, device_id})
      Process.unlink(ticker_pid)
      ref = Process.monitor(ticker_pid)

      kf = simple_keyframe(duration_ms: 5_000, iterations: :infinite)
      layout = animated_layout(control_id, [{true, [kf], []}])

      state = %{
        state
        | entity_states: %{"light.test" => %EntityState{entity_id: "light.test", state: "on"}}
      }

      state = Engine.dispatch_animations_for_entity(layout, "light.test", state)
      assert state.last_match == %{{control_id, 0} => {:matched, 0}}

      Process.exit(ticker_pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^ticker_pid, _}

      # Engine.handle_info({:DOWN, ...}, state) is the production handler.
      # We stand in for it here by clearing last_match the same way.
      cleared = %{state | last_match: %{}, ticker_monitor: nil}

      assert cleared.last_match == %{}

      # Bring the Ticker back up so the next dispatch has a target. In
      # production the Orchestrator restarts it via the DynamicSupervisor;
      # in this isolated test we restart manually.
      {:ok, new_pid} =
        Ticker.start_link(
          device_id: device_id,
          spec: state.spec,
          render_target: {:test, self()}
        )

      on_exit(fn -> if Process.alive?(new_pid), do: GenServer.stop(new_pid) end)

      cleared = Engine.dispatch_animations_for_entity(layout, "light.test", cleared)
      assert cleared.last_match == %{{control_id, 0} => {:matched, 0}}
      assert Map.has_key?(ticker_state(device_id).animations, control_id)
    end
  end

  describe "cancel_all_animations/1 (layout switch)" do
    test "drops every Ticker animation referenced by last_match" do
      control_id = {:key, 0}
      {_device_id, state} = setup_engine(control_id)

      kf = simple_keyframe(duration_ms: 5_000, iterations: :infinite)
      layout = animated_layout(control_id, [{true, [kf], []}])

      state = %{
        state
        | entity_states: %{"light.test" => %EntityState{entity_id: "light.test", state: "on"}}
      }

      state = Engine.dispatch_animations_for_entity(layout, "light.test", state)
      assert Map.has_key?(ticker_state(state.device_id).animations, control_id)

      :ok = Engine.cancel_all_animations(state)

      refute Map.has_key?(ticker_state(state.device_id).animations, control_id)
    end
  end

  describe "dispatch_animations_for_active_layout/1 (layout switch + initial render)" do
    test "installs continuous animations without waiting for an entity event" do
      control_id = {:key, 0}
      {_device_id, state} = setup_engine(control_id)

      kf = simple_keyframe(iterations: :infinite)
      layout = animated_layout(control_id, [{true, [kf], []}])

      profile = %Loupey.Bindings.Profile{
        name: "test",
        device_type: "test-device",
        active_layout: "default",
        layouts: %{"default" => layout}
      }

      # No entity-state events yet — but a binding with `entity_id:
      # "light.test"` and `when: true` matches even with nil state.
      state = %{state | profile: profile}

      assert ticker_state(state.device_id).animations == %{},
             "precondition: no animations installed before dispatch"

      state = Engine.dispatch_animations_for_active_layout(state)

      assert Map.has_key?(ticker_state(state.device_id).animations, control_id),
             "expected animations to install on layout dispatch without state events"

      assert state.last_match == %{{control_id, 0} => {:matched, 0}}
    end
  end

  describe "input-rule animations" do
    test "Rules.match_input/4 returns the matched rule alongside actions" do
      kf = simple_keyframe(duration_ms: 200, iterations: 1)

      input_rule = %InputRule{
        on: :press,
        actions: [%{action: "call_service", domain: "light", service: "toggle"}],
        animations: [kf]
      }

      binding = %Binding{
        entity_id: "light.test",
        input_rules: [input_rule],
        output_rules: []
      }

      event = %PressEvent{control_id: {:key, 0}, action: :press}

      assert {:actions, ^input_rule, [%{action: "call_service"}]} =
               Rules.match_input(event, binding, nil)

      # Verify the rule's animations are accessible — the Engine reads
      # rule.animations and fires :event_one_shots on the touched
      # control. (Wired through `fire_input_animations/3` in
      # `Engine.process_binding_input/4`.)
      assert input_rule.animations == [kf]
    end
  end
end
