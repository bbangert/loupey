defmodule Loupey.AnimationTest do
  @moduledoc """
  Lifecycle tests for `Loupey.Animation` — the DynamicSupervisor that
  owns per-device Tickers. The Orchestrator wires `start_ticker/1` and
  `stop_ticker/1` into engine activation, but those private call-sites
  aren't reachable without booting the full device stack. These tests
  exercise the public API directly.
  """

  use ExUnit.Case, async: false

  alias Loupey.Animation
  alias Loupey.Device.{Control, Display, Spec}

  defp test_spec do
    %Spec{
      type: "test-device",
      controls: [
        %Control{
          id: {:key, 0},
          capabilities: MapSet.new([:display]),
          display: %Display{width: 16, height: 16, pixel_format: :rgb888, display_id: "main"}
        }
      ]
    }
  end

  defp unique_device_id, do: {:animation_test, make_ref()}

  defp assert_eventually(fun, timeout_ms \\ 500, interval_ms \\ 10) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_assert_eventually(fun, deadline, interval_ms)
  end

  defp do_assert_eventually(fun, deadline, interval_ms) do
    if fun.() do
      :ok
    else
      now = System.monotonic_time(:millisecond)

      if now >= deadline do
        flunk("condition did not become true within deadline")
      else
        Process.sleep(interval_ms)
        do_assert_eventually(fun, deadline, interval_ms)
      end
    end
  end

  describe "start_ticker/1" do
    test "starts a Ticker registered under {:ticker, device_id}" do
      device_id = unique_device_id()
      spec = test_spec()

      assert {:ok, pid} =
               Animation.start_ticker(
                 device_id: device_id,
                 spec: spec,
                 render_target: {:test, self()}
               )

      assert is_pid(pid)
      assert [{^pid, _}] = Registry.lookup(Loupey.DeviceRegistry, {:ticker, device_id})

      on_exit(fn -> Animation.stop_ticker(device_id) end)
    end

    test "is idempotent — second call returns existing pid" do
      device_id = unique_device_id()
      spec = test_spec()

      {:ok, pid1} =
        Animation.start_ticker(
          device_id: device_id,
          spec: spec,
          render_target: {:test, self()}
        )

      {:ok, pid2} =
        Animation.start_ticker(
          device_id: device_id,
          spec: spec,
          render_target: {:test, self()}
        )

      assert pid1 == pid2

      on_exit(fn -> Animation.stop_ticker(device_id) end)
    end
  end

  describe "stop_ticker/1" do
    test "terminates the Ticker and removes the registry entry" do
      device_id = unique_device_id()
      spec = test_spec()

      {:ok, pid} =
        Animation.start_ticker(
          device_id: device_id,
          spec: spec,
          render_target: {:test, self()}
        )

      ref = Process.monitor(pid)
      assert :ok = Animation.stop_ticker(device_id)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}

      # Registry cleanup runs via its own monitor on the registered
      # process. The `:DOWN` we just received only proves the Ticker
      # process is dead — Registry's own cleanup may still race. Poll
      # briefly until the entry is gone.
      assert_eventually(fn ->
        Registry.lookup(Loupey.DeviceRegistry, {:ticker, device_id}) == []
      end)
    end

    test "is a no-op when no Ticker exists for the device" do
      assert :ok = Animation.stop_ticker({:never_started, make_ref()})
    end
  end
end
