defmodule Loupey.Animation.TickerTest do
  use ExUnit.Case, async: false

  alias Loupey.Animation.{Keyframes, Ticker}
  alias Loupey.Device.{Control, Display, Spec}

  defp test_spec(control_id) do
    %Spec{
      type: "test-device",
      controls: [
        %Control{
          id: control_id,
          capabilities: MapSet.new([:display]),
          display: %Display{width: 16, height: 16, pixel_format: :rgb888, display_id: "main"}
        }
      ]
    }
  end

  defp simple_keyframe(opts \\ []) do
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

  defp start_ticker_for_test(control_id) do
    spec = test_spec(control_id)
    device_id = {:test_ticker, make_ref()}

    {:ok, pid} =
      Ticker.start_link(
        device_id: device_id,
        spec: spec,
        render_target: {:test, self()}
      )

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    {device_id, pid}
  end

  defp drain_render_messages(timeout_ms \\ 50) do
    receive do
      {:ticker_render, _cmd} = msg ->
        [msg | drain_render_messages(timeout_ms)]
    after
      timeout_ms -> []
    end
  end

  describe "start_link/1" do
    test "registers via the device registry" do
      {device_id, pid} = start_ticker_for_test({:key, 0})

      assert [{^pid, _}] = Registry.lookup(Loupey.DeviceRegistry, {:ticker, device_id})
    end

    test "tick loop renders no commands when no animations are installed" do
      {_device_id, _pid} = start_ticker_for_test({:key, 0})
      # 100 ms is ~3 ticks at @tick_ms=33. `refute_receive` blocks until
      # the timeout AND fails fast if any unexpected message arrives,
      # whereas `Process.sleep + drain` only catches messages already
      # delivered when sleep returns.
      refute_receive {:ticker_render, _}, 100
    end

    test "tick loop is idle until first animation; resumes on install; pauses on cancel" do
      control_id = {:key, 0}
      {device_id, pid} = start_ticker_for_test(control_id)

      # No `:tick` message in the mailbox after init — the loop is
      # not scheduled until an animation lands.
      assert mailbox_count(pid) == 0

      kf = simple_keyframe(duration_ms: 200, iterations: :infinite)
      :ok = Ticker.start_animation(device_id, control_id, :continuous, kf, %{})
      Process.sleep(120)
      assert_received {:ticker_render, _}

      :ok = Ticker.cancel_all(device_id, control_id)
      # Drain anything still in flight from the just-completed tick.
      _ = drain_render_messages(50)

      # After cancel the loop pauses: nothing should arrive over a
      # 100 ms window where 3+ ticks would otherwise have fired.
      refute_receive {:ticker_render, _}, 100
    end
  end

  defp mailbox_count(pid) do
    {:messages, msgs} = Process.info(pid, :messages)
    Enum.count(msgs, &match?(:tick, &1))
  end

  describe "start_animation/5 — continuous" do
    test "produces multiple frames over the duration" do
      control_id = {:key, 0}
      {device_id, _pid} = start_ticker_for_test(control_id)

      kf = simple_keyframe(duration_ms: 200, iterations: 1)

      :ok =
        Ticker.start_animation(device_id, control_id, :continuous, kf, %{background: "#000000"})

      Process.sleep(250)
      msgs = drain_render_messages()

      # 30 fps × ~250 ms ≈ 7-8 frames; allow slack for scheduler jitter.
      assert length(msgs) >= 4
      assert Enum.all?(msgs, &match?({:ticker_render, %_{}}, &1))
    end
  end

  describe "start_animation/5 — one_shot" do
    test "auto-removes from state when complete" do
      control_id = {:key, 0}
      {device_id, _pid} = start_ticker_for_test(control_id)

      kf = simple_keyframe(duration_ms: 100, iterations: 1)
      :ok = Ticker.start_animation(device_id, control_id, :one_shot, kf, %{background: "#000000"})

      assert %{animations: anims} = Ticker.get_state(device_id)
      assert Map.has_key?(anims, control_id)

      Process.sleep(200)
      drain_render_messages()

      assert %{animations: %{}} = Ticker.get_state(device_id)
    end
  end

  describe "cancel_all/2" do
    test "drops all animations for a control" do
      control_id = {:key, 0}
      {device_id, _pid} = start_ticker_for_test(control_id)

      kf = simple_keyframe(duration_ms: 5_000, iterations: :infinite)
      :ok = Ticker.start_animation(device_id, control_id, :continuous, kf, %{})

      assert %{animations: anims} = Ticker.get_state(device_id)
      assert Map.has_key?(anims, control_id)

      :ok = Ticker.cancel_all(device_id, control_id)

      assert %{animations: %{}} = Ticker.get_state(device_id)
    end

    test "cancel_all also drops :event_one_shot flights (hard reset)" do
      control_id = {:key, 0}
      {device_id, _pid} = start_ticker_for_test(control_id)

      kf = simple_keyframe(duration_ms: 5_000, iterations: 1)
      :ok = Ticker.start_animation(device_id, control_id, :event_one_shot, kf, %{})

      :ok = Ticker.cancel_all(device_id, control_id)

      assert %{animations: %{}} = Ticker.get_state(device_id)
    end
  end

  describe "cancel_rule_animations/2" do
    test "drops :continuous flights but preserves :event_one_shot flights" do
      control_id = {:key, 0}
      {device_id, _pid} = start_ticker_for_test(control_id)

      cont_kf = simple_keyframe(duration_ms: 5_000, iterations: :infinite)
      touch_kf = simple_keyframe(duration_ms: 200, iterations: 1)

      :ok = Ticker.start_animation(device_id, control_id, :continuous, cont_kf, %{})
      :ok = Ticker.start_animation(device_id, control_id, :event_one_shot, touch_kf, %{})

      :ok = Ticker.cancel_rule_animations(device_id, control_id)

      ctl = Ticker.get_state(device_id).animations[control_id]
      assert ctl.continuous == [], "continuous flight should be dropped"
      assert [event_flight] = ctl.one_shots
      assert event_flight.kind == :event_one_shot
    end

    test "drops :one_shot (on_enter / on_change) flights" do
      control_id = {:key, 0}
      {device_id, _pid} = start_ticker_for_test(control_id)

      kf = simple_keyframe(duration_ms: 5_000, iterations: 1)
      :ok = Ticker.start_animation(device_id, control_id, :one_shot, kf, %{})

      :ok = Ticker.cancel_rule_animations(device_id, control_id)

      assert %{animations: %{}} = Ticker.get_state(device_id),
             "rule-bound :one_shot should be dropped along with the empty entry"
    end

    test "drops :property_transition flights (synthetic transitions tagged with path)" do
      control_id = {:key, 0}
      {device_id, _pid} = start_ticker_for_test(control_id)

      kf = simple_keyframe(duration_ms: 5_000, iterations: 1)
      :ok = Ticker.start_property_transition(device_id, control_id, kf, %{}, [:fill, :amount])

      :ok = Ticker.cancel_rule_animations(device_id, control_id)

      assert %{animations: %{}} = Ticker.get_state(device_id)
    end

    test "no-op when control has no animations installed" do
      control_id = {:key, 0}
      {device_id, _pid} = start_ticker_for_test(control_id)

      :ok = Ticker.cancel_rule_animations(device_id, control_id)

      assert %{animations: %{}} = Ticker.get_state(device_id)
    end
  end

  describe "refresh_base/3" do
    test "updates base_instructions for an active animation" do
      control_id = {:key, 0}
      {device_id, _pid} = start_ticker_for_test(control_id)

      kf = simple_keyframe(duration_ms: 5_000, iterations: 1)
      :ok = Ticker.start_animation(device_id, control_id, :event_one_shot, kf, %{icon: "old.png"})

      :ok = Ticker.refresh_base(device_id, control_id, %{icon: "new.png"})

      assert %{icon: "new.png"} =
               Ticker.get_state(device_id).animations[control_id].base_instructions
    end

    test "no-op when control has no animations installed" do
      control_id = {:key, 0}
      {device_id, _pid} = start_ticker_for_test(control_id)

      :ok = Ticker.refresh_base(device_id, control_id, %{icon: "new.png"})

      # Doesn't crash, doesn't create a phantom animation entry.
      assert %{animations: %{}} = Ticker.get_state(device_id)
    end
  end

  describe "tick cadence" do
    test "stays close to 33 ms over a 1-second window" do
      control_id = {:key, 0}
      {device_id, _pid} = start_ticker_for_test(control_id)

      kf = simple_keyframe(duration_ms: 5_000, iterations: :infinite)
      :ok = Ticker.start_animation(device_id, control_id, :continuous, kf, %{})

      Process.sleep(1_000)
      :ok = Ticker.cancel_all(device_id, control_id)

      msgs = drain_render_messages(80)

      # 1000 ms / 33 ms ≈ 30 frames. Be generous on jitter — schedulers
      # are noisy under test load. We mainly want to detect order-of-
      # magnitude regressions (e.g., 5 fps or 100 fps).
      count = length(msgs)
      assert count >= 20, "expected ~30 frames, got #{count}"
      assert count <= 45, "expected ~30 frames, got #{count}"
    end
  end

  describe "render target injection" do
    test "function render targets are called per frame" do
      control_id = {:key, 0}
      spec = test_spec(control_id)
      device_id = {:test_ticker, make_ref()}
      parent = self()
      target = fn cmd -> send(parent, {:fun_render, cmd}) end

      {:ok, pid} =
        Ticker.start_link(device_id: device_id, spec: spec, render_target: target)

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      kf = simple_keyframe(duration_ms: 200, iterations: 1)
      :ok = Ticker.start_animation(device_id, control_id, :continuous, kf, %{})

      Process.sleep(150)
      assert_received {:fun_render, _}
    end
  end

  describe "invalid control" do
    test "start_animation for unknown control_id is a no-op" do
      {device_id, _pid} = start_ticker_for_test({:key, 0})

      kf = simple_keyframe()

      :ok =
        Ticker.start_animation(
          device_id,
          {:does_not_exist, 99},
          :continuous,
          kf,
          %{}
        )

      assert %{animations: %{}} = Ticker.get_state(device_id)
    end
  end
end
