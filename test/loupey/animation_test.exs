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
      assert Registry.lookup(Loupey.DeviceRegistry, {:ticker, device_id}) == []
    end

    test "is a no-op when no Ticker exists for the device" do
      assert :ok = Animation.stop_ticker({:never_started, make_ref()})
    end
  end
end
