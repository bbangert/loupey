defmodule Loupey.DeviceServerTest do
  use ExUnit.Case, async: false

  alias Loupey.Devices
  alias Loupey.DeviceServer
  alias Loupey.Driver.Fake
  alias Loupey.Events.PressEvent

  setup do
    # Unique device_id per test so the via-registry name is free.
    id = "fake_#{System.unique_integer([:positive])}"

    {:ok, device_pid} =
      DeviceServer.start_link(
        driver: Fake,
        device_ref: self(),
        device_id: id
      )

    {:ok, %{device_id: id, device_pid: device_pid}}
  end

  test "driver.open/2 is called with the device server as parent", %{device_pid: pid} do
    assert_receive {:fake_driver, {:open, opts}}
    assert Keyword.fetch!(opts, :parent) == pid
  end

  test "render casts go through driver.encode/1 + driver.send_command/2", %{device_id: id} do
    # Drain the open message first
    assert_receive {:fake_driver, {:open, _}}

    :ok = DeviceServer.render(id, %Loupey.RenderCommands.SetBrightness{level: 0.5})
    assert_receive {:fake_driver, {:send_command, {0x99, "encoded"}}}
  end

  test "refresh casts use encode_refresh when driver exports it", %{device_id: id} do
    assert_receive {:fake_driver, {:open, _}}

    :ok = DeviceServer.refresh(id, <<0x01>>)
    assert_receive {:fake_driver, {:send_command, {0x9A, <<0x01>>}}}
  end

  test "incoming {:device_data, bytes} is parsed and broadcast", %{
    device_id: id,
    device_pid: pid
  } do
    assert_receive {:fake_driver, {:open, _}}
    :ok = Devices.subscribe(id)

    # The real Fake driver's parse/2 returns []; exercise the shape with a
    # direct message to confirm the server dispatches to parse without
    # crashing and doesn't die on empty-event input.
    send(pid, {:device_data, <<1, 2, 3>>})
    refute_receive {:device_event, ^id, %PressEvent{}}, 100
    assert Process.alive?(pid)
  end

  test "driver.close/1 is called on terminate", %{device_pid: pid} do
    assert_receive {:fake_driver, {:open, _}}

    GenServer.stop(pid, :normal)
    assert_receive {:fake_driver, :close}
  end
end
