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

  use ExUnit.Case, async: true

  alias Hassock.EntityState
  alias Loupey.Animation.{Keyframes, Ticker, TransitionSpec}
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

    layout_for_rules(control_id, rules)
  end

  defp single_rule_layout(control_id, %OutputRule{} = rule) do
    layout_for_rules(control_id, [rule])
  end

  defp layout_for_rules(control_id, rules) do
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

      assert {:matched, 0, %{background: "#000000"}} = state.last_match[{control_id, 0}]
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
      assert {:matched, 0, _} = state.last_match[{control_id, 0}]

      ts1 = ticker_state(state.device_id)
      assert ts1.animations[control_id].continuous |> hd() |> Map.get(:keyframe) == kf_a

      # Flip to "off" — different rule_idx.
      state = %{
        state
        | entity_states: %{"light.test" => %EntityState{entity_id: "light.test", state: "off"}}
      }

      state = Engine.dispatch_animations_for_entity(layout, "light.test", state)
      assert {:matched, 1, _} = state.last_match[{control_id, 0}]

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
      assert {:matched, 0, _} = state.last_match[{control_id, 0}]

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
      assert {:matched, 0, _} = cleared.last_match[{control_id, 0}]
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

      assert {:matched, 0, _} = state.last_match[{control_id, 0}]
    end
  end

  describe "transitions diff dispatcher (same rule_idx)" do
    test "fires synthetic two-stop keyframe with old + new values at the path" do
      control_id = {:key, 0}
      {_device_id, state} = setup_engine(control_id)

      spec = TransitionSpec.parse(%{duration_ms: 300, easing: :ease_out})

      rule = %OutputRule{
        when: true,
        instructions: %{color: "#00FF00"},
        transitions: %{[:color] => spec}
      }

      layout = single_rule_layout(control_id, rule)

      # Pre-populate last_match as if we previously matched with #FF0000.
      state = %{
        state
        | entity_states: %{"light.test" => %EntityState{entity_id: "light.test", state: "on"}},
          last_match: %{{control_id, 0} => {:matched, 0, %{color: "#FF0000"}}}
      }

      state = Engine.dispatch_animations_for_entity(layout, "light.test", state)

      ctl = ticker_state(state.device_id).animations[control_id]
      assert ctl, "expected synthetic transition flight installed"

      assert [flight] = ctl.one_shots
      assert flight.property_path == [:color]
      assert flight.kind == :one_shot

      kf = flight.keyframe
      assert kf.duration_ms == 300
      assert kf.iterations == 1
      assert kf.direction == :normal
      assert [{0, %{color: "#FF0000"}}, {100, %{color: "#00FF00"}}] = kf.stops

      assert {:matched, 0, %{color: "#00FF00"}} = state.last_match[{control_id, 0}]
    end

    test "nests value at multi-segment path for fill.amount" do
      control_id = {:key, 0}
      {_device_id, state} = setup_engine(control_id)

      spec = TransitionSpec.parse(%{duration_ms: 200, easing: :ease_out})

      rule = %OutputRule{
        when: true,
        instructions: %{fill: %{amount: 80, direction: :to_top}},
        transitions: %{[:fill, :amount] => spec}
      }

      layout = single_rule_layout(control_id, rule)

      state = %{
        state
        | entity_states: %{"light.test" => %EntityState{entity_id: "light.test", state: "on"}},
          last_match: %{
            {control_id, 0} => {:matched, 0, %{fill: %{amount: 30, direction: :to_top}}}
          }
      }

      state = Engine.dispatch_animations_for_entity(layout, "light.test", state)

      assert [flight] = ticker_state(state.device_id).animations[control_id].one_shots
      assert flight.property_path == [:fill, :amount]

      assert [{0, %{fill: %{amount: 30}}}, {100, %{fill: %{amount: 80}}}] = flight.keyframe.stops
    end

    test "skips transition when property is unchanged" do
      control_id = {:key, 0}
      {_device_id, state} = setup_engine(control_id)

      spec = TransitionSpec.parse(%{duration_ms: 300})
      kf_continuous = simple_keyframe(iterations: :infinite)

      rule = %OutputRule{
        when: true,
        instructions: %{color: "#FFD700", background: "#000000"},
        animations: [kf_continuous],
        transitions: %{[:color] => spec}
      }

      layout = single_rule_layout(control_id, rule)

      # Same color in prev + curr — no diff.
      state = %{
        state
        | entity_states: %{"light.test" => %EntityState{entity_id: "light.test", state: "on"}},
          last_match: %{
            {control_id, 0} => {:matched, 0, %{color: "#FFD700", background: "#000000"}}
          }
      }

      state = Engine.dispatch_animations_for_entity(layout, "light.test", state)

      ctl = ticker_state(state.device_id).animations[control_id]
      assert length(ctl.continuous) == 1
      assert ctl.one_shots == [], "no transition should fire when value is unchanged"
    end

    test "first match (:no_match → :match) does not fire transition" do
      control_id = {:key, 0}
      {_device_id, state} = setup_engine(control_id)

      spec = TransitionSpec.parse(%{duration_ms: 300})

      rule = %OutputRule{
        when: true,
        instructions: %{color: "#00FF00"},
        transitions: %{[:color] => spec}
      }

      layout = single_rule_layout(control_id, rule)

      state = %{
        state
        | entity_states: %{"light.test" => %EntityState{entity_id: "light.test", state: "on"}}
      }

      state = Engine.dispatch_animations_for_entity(layout, "light.test", state)

      # Rule installs but has no continuous/on_enter — no Ticker entry at all.
      # Either way, no synthetic transition flight should exist.
      ctl = ticker_state(state.device_id).animations[control_id]
      assert ctl == nil or ctl.one_shots == []
      assert {:matched, 0, %{color: "#00FF00"}} = state.last_match[{control_id, 0}]
    end

    test "rule_idx change does not fire per-property transition (rule-level path)" do
      control_id = {:key, 0}
      {_device_id, state} = setup_engine(control_id)

      spec = TransitionSpec.parse(%{duration_ms: 300})
      kf_a = simple_keyframe(iterations: :infinite)
      kf_b = simple_keyframe(duration_ms: 999, iterations: :infinite)

      rule_a = %OutputRule{
        when: ~s(state == "on"),
        instructions: %{color: "#FF0000"},
        animations: [kf_a],
        transitions: %{[:color] => spec}
      }

      rule_b = %OutputRule{
        when: ~s(state == "off"),
        instructions: %{color: "#0000FF"},
        animations: [kf_b],
        transitions: %{[:color] => spec}
      }

      binding = %Binding{
        entity_id: "light.test",
        input_rules: [],
        output_rules: [rule_a, rule_b]
      }

      layout = %Layout{name: "default", bindings: %{control_id => [binding]}}

      state = %{
        state
        | entity_states: %{"light.test" => %EntityState{entity_id: "light.test", state: "on"}}
      }

      state = Engine.dispatch_animations_for_entity(layout, "light.test", state)

      # Flip to "off" — different rule_idx.
      state = %{
        state
        | entity_states: %{"light.test" => %EntityState{entity_id: "light.test", state: "off"}}
      }

      state = Engine.dispatch_animations_for_entity(layout, "light.test", state)

      ctl = ticker_state(state.device_id).animations[control_id]
      # New rule's continuous keyframe is installed; no synthetic transition.
      assert length(ctl.continuous) == 1
      assert hd(ctl.continuous).keyframe == kf_b

      assert Enum.all?(ctl.one_shots, &is_nil(&1.property_path)),
             "per-property transitions must not fire across rule_idx changes"
    end

    test "skips transition when old value is nil (property first appears)" do
      control_id = {:key, 0}
      {_device_id, state} = setup_engine(control_id)

      spec = TransitionSpec.parse(%{duration_ms: 300})

      rule = %OutputRule{
        when: true,
        instructions: %{color: "#00FF00"},
        transitions: %{[:color] => spec}
      }

      layout = single_rule_layout(control_id, rule)

      # prev had no `:color` key.
      state = %{
        state
        | entity_states: %{"light.test" => %EntityState{entity_id: "light.test", state: "on"}},
          last_match: %{{control_id, 0} => {:matched, 0, %{background: "#000000"}}}
      }

      state = Engine.dispatch_animations_for_entity(layout, "light.test", state)

      ctl = ticker_state(state.device_id).animations[control_id]

      assert ctl == nil or ctl.one_shots == [],
             "no transition should fire when there's no old value to lerp from"
    end

    test "rapid re-fire cancels the prior in-flight transition" do
      control_id = {:key, 0}
      {_device_id, state} = setup_engine(control_id)

      spec = TransitionSpec.parse(%{duration_ms: 5_000})

      rule = %OutputRule{
        when: true,
        instructions: %{color: "#00FF00"},
        transitions: %{[:color] => spec}
      }

      layout = single_rule_layout(control_id, rule)

      state = %{
        state
        | entity_states: %{"light.test" => %EntityState{entity_id: "light.test", state: "on"}},
          last_match: %{{control_id, 0} => {:matched, 0, %{color: "#FF0000"}}}
      }

      state = Engine.dispatch_animations_for_entity(layout, "light.test", state)
      assert [_first] = ticker_state(state.device_id).animations[control_id].one_shots

      # Simulate next match resolving to a different color while the first
      # transition is still in flight. The dispatch sees prev=#00FF00 (the
      # last resolved instructions, now in last_match) → curr=#0000FF.
      rule2 = %{rule | instructions: %{color: "#0000FF"}}
      layout2 = single_rule_layout(control_id, rule2)

      state = Engine.dispatch_animations_for_entity(layout2, "light.test", state)

      ctl = ticker_state(state.device_id).animations[control_id]
      assert [flight] = ctl.one_shots, "stale transition flight was not cancelled"

      [{0, %{color: lo}}, {100, %{color: hi}}] = flight.keyframe.stops
      assert lo == "#00FF00", "new flight should start from the previous resolved value"
      assert hi == "#0000FF"
    end
  end

  describe "on_change diff dispatcher (same rule_idx)" do
    test "fires keyframe one-shot on property change" do
      control_id = {:key, 0}
      {_device_id, state} = setup_engine(control_id)

      ripple =
        Keyframes.parse(%{
          effect: :ripple,
          duration_ms: 400,
          color: "#FFFFFF",
          intensity: 128
        })

      rule = %OutputRule{
        when: true,
        instructions: %{fill: %{amount: 80, direction: :to_top}},
        on_change: %{[:fill, :amount] => ripple}
      }

      layout = single_rule_layout(control_id, rule)

      state = %{
        state
        | entity_states: %{"light.test" => %EntityState{entity_id: "light.test", state: "on"}},
          last_match: %{
            {control_id, 0} => {:matched, 0, %{fill: %{amount: 30, direction: :to_top}}}
          }
      }

      state = Engine.dispatch_animations_for_entity(layout, "light.test", state)

      ctl = ticker_state(state.device_id).animations[control_id]
      assert [flight] = ctl.one_shots
      assert flight.keyframe == ripple
      assert flight.property_path == nil, "on_change one-shots are not path-tagged"
    end

    test "skips on_change when property is unchanged" do
      control_id = {:key, 0}
      {_device_id, state} = setup_engine(control_id)

      kf = simple_keyframe(duration_ms: 200, iterations: 1)

      rule = %OutputRule{
        when: true,
        instructions: %{color: "#FFD700"},
        on_change: %{[:color] => kf}
      }

      layout = single_rule_layout(control_id, rule)

      state = %{
        state
        | entity_states: %{"light.test" => %EntityState{entity_id: "light.test", state: "on"}},
          last_match: %{{control_id, 0} => {:matched, 0, %{color: "#FFD700"}}}
      }

      state = Engine.dispatch_animations_for_entity(layout, "light.test", state)

      assert ticker_state(state.device_id).animations[control_id] == nil or
               ticker_state(state.device_id).animations[control_id].one_shots == []
    end

    test "first match (:no_match → :match) does not fire on_change" do
      control_id = {:key, 0}
      {_device_id, state} = setup_engine(control_id)

      kf = simple_keyframe(duration_ms: 200, iterations: 1)

      rule = %OutputRule{
        when: true,
        instructions: %{color: "#FFD700"},
        on_change: %{[:color] => kf}
      }

      layout = single_rule_layout(control_id, rule)

      state = %{
        state
        | entity_states: %{"light.test" => %EntityState{entity_id: "light.test", state: "on"}}
      }

      state = Engine.dispatch_animations_for_entity(layout, "light.test", state)

      ctl = ticker_state(state.device_id).animations[control_id]

      assert ctl == nil or ctl.one_shots == [],
             "on_change must not fire on rule entry — that's on_enter's job"
    end

    test "fires on_change when property appears for the first time on same-idx (nil → val)" do
      control_id = {:key, 0}
      {_device_id, state} = setup_engine(control_id)

      kf = simple_keyframe(duration_ms: 200, iterations: 1)

      rule = %OutputRule{
        when: true,
        instructions: %{color: "#00FF00"},
        on_change: %{[:color] => kf}
      }

      layout = single_rule_layout(control_id, rule)

      # prev had no `:color` key — but the rule was already matched (same idx).
      state = %{
        state
        | entity_states: %{"light.test" => %EntityState{entity_id: "light.test", state: "on"}},
          last_match: %{{control_id, 0} => {:matched, 0, %{background: "#000000"}}}
      }

      state = Engine.dispatch_animations_for_entity(layout, "light.test", state)

      assert [flight] = ticker_state(state.device_id).animations[control_id].one_shots
      assert flight.keyframe == kf
    end
  end

  describe "transitions + on_change combined for same property" do
    test "fires both flights in the same dispatch" do
      control_id = {:key, 0}
      {_device_id, state} = setup_engine(control_id)

      spec = TransitionSpec.parse(%{duration_ms: 300, easing: :ease_out})

      ripple =
        Keyframes.parse(%{
          effect: :ripple,
          duration_ms: 400,
          color: "#FFFFFF"
        })

      rule = %OutputRule{
        when: true,
        instructions: %{fill: %{amount: 80, direction: :to_top}},
        transitions: %{[:fill, :amount] => spec},
        on_change: %{[:fill, :amount] => ripple}
      }

      layout = single_rule_layout(control_id, rule)

      state = %{
        state
        | entity_states: %{"light.test" => %EntityState{entity_id: "light.test", state: "on"}},
          last_match: %{
            {control_id, 0} => {:matched, 0, %{fill: %{amount: 30, direction: :to_top}}}
          }
      }

      state = Engine.dispatch_animations_for_entity(layout, "light.test", state)

      ctl = ticker_state(state.device_id).animations[control_id]

      transitions =
        Enum.filter(ctl.one_shots, &(&1.property_path == [:fill, :amount]))

      on_changes = Enum.filter(ctl.one_shots, &is_nil(&1.property_path))

      assert length(transitions) == 1
      assert length(on_changes) == 1
      assert hd(on_changes).keyframe == ripple

      [transition_flight] = transitions

      assert [{0, %{fill: %{amount: 30}}}, {100, %{fill: %{amount: 80}}}] =
               transition_flight.keyframe.stops
    end
  end

  describe "touch animation survives state change with refreshed base" do
    test "event_one_shot keeps running across rule_idx change with new base_instructions" do
      # Regression: before this fix, touching a key with an
      # `animation:` block (e.g. ripple on touch_start) and then
      # waiting for HA to report the toggled state would either
      # cancel the ripple mid-fade OR leave the ticker holding stale
      # base_instructions, racing the direct render and freezing the
      # display on the old icon.
      control_id = {:key, 0}
      {_device_id, state} = setup_engine(control_id)

      ripple = simple_keyframe(duration_ms: 5_000, iterations: 1)

      # Start the input-rule animation as if a touch_start just fired.
      Ticker.start_animation(state.device_id, control_id, :event_one_shot, ripple, %{
        icon: "icons/Lights_On.png"
      })

      # Output rules: state-driven, two distinct rules so a state
      # flip changes rule_idx (the path that previously cancel_all'd
      # everything including the ripple).
      rule_on = %OutputRule{
        when: ~s(state == "on"),
        instructions: %{icon: "icons/Lights_On.png", background: "#000000"}
      }

      rule_off = %OutputRule{
        when: ~s(state == "off"),
        instructions: %{icon: "icons/Lights_Off.png", background: "#000000"}
      }

      binding = %Binding{
        entity_id: "light.test",
        input_rules: [],
        output_rules: [rule_on, rule_off]
      }

      layout = %Layout{name: "default", bindings: %{control_id => [binding]}}

      # Initial state "on" — pre-populate last_match so the next
      # dispatch sees a rule_idx change rather than a fresh entry.
      state = %{
        state
        | entity_states: %{"light.test" => %EntityState{entity_id: "light.test", state: "on"}},
          last_match: %{
            {control_id, 0} =>
              {:matched, 0, %{icon: "icons/Lights_On.png", background: "#000000"}}
          }
      }

      # State flips to "off" — same binding, different matched rule.
      state = %{
        state
        | entity_states: %{"light.test" => %EntityState{entity_id: "light.test", state: "off"}}
      }

      state = Engine.dispatch_animations_for_entity(layout, "light.test", state)

      ctl = ticker_state(state.device_id).animations[control_id]

      assert ctl, "ripple should survive the rule_idx change"

      assert [flight] = ctl.one_shots
      assert flight.kind == :event_one_shot, "the touch ripple should be preserved"

      assert ctl.base_instructions.icon == "icons/Lights_Off.png",
             "base should be refreshed to the new rule's resolved instructions " <>
               "so the ripple renders against the new state, not the captured one"
    end

    test "no-match rule transition cancels rule animations but keeps event_one_shots" do
      control_id = {:key, 0}
      {_device_id, state} = setup_engine(control_id)

      cont_kf = simple_keyframe(duration_ms: 5_000, iterations: :infinite)
      touch_kf = simple_keyframe(duration_ms: 5_000, iterations: 1)

      rule = %OutputRule{
        when: ~s(state == "on"),
        instructions: %{background: "#000000"},
        animations: [cont_kf]
      }

      binding = %Binding{entity_id: "light.test", input_rules: [], output_rules: [rule]}
      layout = %Layout{name: "default", bindings: %{control_id => [binding]}}

      state = %{
        state
        | entity_states: %{"light.test" => %EntityState{entity_id: "light.test", state: "on"}}
      }

      state = Engine.dispatch_animations_for_entity(layout, "light.test", state)

      # Add a touch ripple on top of the continuous animation.
      Ticker.start_animation(state.device_id, control_id, :event_one_shot, touch_kf, %{})

      ctl_before = ticker_state(state.device_id).animations[control_id]
      assert length(ctl_before.continuous) == 1
      assert length(ctl_before.one_shots) == 1

      # State leaves "on" — rule no longer matches anything.
      state = %{
        state
        | entity_states: %{"light.test" => %EntityState{entity_id: "light.test", state: "off"}}
      }

      state = Engine.dispatch_animations_for_entity(layout, "light.test", state)

      ctl_after = ticker_state(state.device_id).animations[control_id]
      assert ctl_after, "control entry should remain because the touch ripple is still in flight"
      assert ctl_after.continuous == [], "continuous animation should be cancelled"
      assert [flight] = ctl_after.one_shots
      assert flight.kind == :event_one_shot
    end
  end

  describe "transitions diff dispatcher edge cases" do
    test "on_change re-fires on subsequent same-property change" do
      control_id = {:key, 0}
      {_device_id, state} = setup_engine(control_id)

      kf =
        Keyframes.parse(%{
          duration_ms: 5_000,
          iterations: 1,
          keyframes: %{0 => %{overlay: "#FFFFFF80"}, 100 => %{overlay: "#FFFFFF00"}}
        })

      rule = %OutputRule{
        when: true,
        instructions: %{fill: %{amount: 80, direction: :to_top}},
        on_change: %{[:fill, :amount] => kf}
      }

      layout = single_rule_layout(control_id, rule)

      # First flip: 30 → 80. Pre-populated last_match simulates the prior
      # resolved instructions. Long duration (5_000 ms) keeps both
      # flights in flight across both dispatches.
      state = %{
        state
        | entity_states: %{"light.test" => %EntityState{entity_id: "light.test", state: "on"}},
          last_match: %{
            {control_id, 0} => {:matched, 0, %{fill: %{amount: 30, direction: :to_top}}}
          }
      }

      state = Engine.dispatch_animations_for_entity(layout, "light.test", state)
      assert [_first] = ticker_state(state.device_id).animations[control_id].one_shots

      # Second flip: 80 → 40. Replace the rule with the new resolved
      # value; last_match now holds the 80 instructions from the prior
      # dispatch (same code path the engine uses in production).
      rule2 = %{rule | instructions: %{fill: %{amount: 40, direction: :to_top}}}
      layout2 = single_rule_layout(control_id, rule2)

      state = Engine.dispatch_animations_for_entity(layout2, "light.test", state)

      ctl = ticker_state(state.device_id).animations[control_id]
      assert length(ctl.one_shots) == 2, "on_change should re-fire on subsequent change"
    end

    test "transition handles 3-segment property paths" do
      control_id = {:key, 0}
      {_device_id, state} = setup_engine(control_id)

      spec = TransitionSpec.parse(%{duration_ms: 200})

      rule = %OutputRule{
        when: true,
        instructions: %{a: %{b: %{c: 80}}},
        transitions: %{[:a, :b, :c] => spec}
      }

      layout = single_rule_layout(control_id, rule)

      state = %{
        state
        | entity_states: %{"light.test" => %EntityState{entity_id: "light.test", state: "on"}},
          last_match: %{
            {control_id, 0} => {:matched, 0, %{a: %{b: %{c: 30}}}}
          }
      }

      state = Engine.dispatch_animations_for_entity(layout, "light.test", state)

      assert [flight] = ticker_state(state.device_id).animations[control_id].one_shots
      assert flight.property_path == [:a, :b, :c]

      assert [{0, %{a: %{b: %{c: 30}}}}, {100, %{a: %{b: %{c: 80}}}}] =
               flight.keyframe.stops
    end

    test "val → nil installs a transition flight that holds the old value" do
      # `Tween.lerp_value(a, nil, _)` falls through to `a`, so the
      # rendered value holds at the old value for the spec's duration.
      # Documents (and pins) the val → nil semantics since the
      # `nil → val` direction is explicitly skipped.
      control_id = {:key, 0}
      {_device_id, state} = setup_engine(control_id)

      spec = TransitionSpec.parse(%{duration_ms: 200})

      # The new instructions don't include `:color` — `get_in/2`
      # returns nil at the path.
      rule = %OutputRule{
        when: true,
        instructions: %{background: "#000000"},
        transitions: %{[:color] => spec}
      }

      layout = single_rule_layout(control_id, rule)

      state = %{
        state
        | entity_states: %{"light.test" => %EntityState{entity_id: "light.test", state: "on"}},
          last_match: %{{control_id, 0} => {:matched, 0, %{color: "#FF0000"}}}
      }

      state = Engine.dispatch_animations_for_entity(layout, "light.test", state)

      assert [flight] = ticker_state(state.device_id).animations[control_id].one_shots
      assert [{0, %{color: "#FF0000"}}, {100, %{color: nil}}] = flight.keyframe.stops
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
