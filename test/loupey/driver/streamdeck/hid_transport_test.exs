defmodule Loupey.Driver.Streamdeck.HidTransportTest do
  # async: false — the fake HidPort resolves its controller via
  # Process.whereis(:fake_hid_controller), which is a global name.
  use ExUnit.Case, async: false

  alias Loupey.Driver.Streamdeck.HidTransport

  defmodule FakeHidPort do
    @moduledoc """
    Test HidPort. The test process registers itself as `:fake_hid_controller`;
    the port's `open/1` returns that pid as the handle. Reads and writes
    flow as messages to/from the controller, so tests can assert on and
    script each call.
    """
    @behaviour Loupey.Driver.Streamdeck.HidPort

    @controller_name :fake_hid_controller

    @impl true
    def enumerate, do: []

    @impl true
    def open(_path) do
      case Process.whereis(@controller_name) do
        nil -> {:error, :no_controller}
        pid -> {:ok, pid}
      end
    end

    @impl true
    def close(pid) do
      send(pid, {:fake_hid, :close})
      :ok
    end

    @impl true
    def read(pid, size) do
      ref = make_ref()
      send(pid, {:fake_hid_read, self(), ref, size})

      receive do
        {^ref, result} -> result
      end
    end

    @impl true
    def write_output_report(pid, data) do
      send(pid, {:fake_hid, {:write_output, data}})
      {:ok, byte_size(data)}
    end

    @impl true
    def write_feature_report(pid, data) do
      send(pid, {:fake_hid, {:write_feature, data}})
      {:ok, byte_size(data)}
    end
  end

  setup do
    # Trap exits so a transport crash during error-path tests doesn't kill
    # the test process (start_link links the transport to us).
    Process.flag(:trap_exit, true)
    Process.register(self(), :fake_hid_controller)
    :ok
  end

  defp start_transport(opts \\ []) do
    opts =
      Keyword.merge(
        [parent: self(), port_mod: FakeHidPort, input_report_size: 19],
        opts
      )

    HidTransport.start_link("fake-path", opts)
  end

  describe "open/close lifecycle" do
    test "open returns {:error, _} when the port's open fails" do
      Process.unregister(:fake_hid_controller)
      assert {:error, {:hid_open_failed, :no_controller}} = start_transport()
      Process.register(self(), :fake_hid_controller)
    end

    test "close/1 calls HidPort.close on the handle and stops" do
      {:ok, pid} = start_transport()
      assert_receive {:fake_hid_read, _reader, _ref, 19}
      ref = Process.monitor(pid)

      :ok = HidTransport.close(pid)

      assert_receive {:DOWN, ^ref, :process, ^pid, _}
      assert_receive {:fake_hid, :close}
    end
  end

  describe "read path" do
    test "forwards incoming bytes to the parent as {:device_data, bytes}" do
      {:ok, _pid} = start_transport()
      assert_receive {:fake_hid_read, reader, ref, 19}, 500

      payload = <<0x01, 0, 0, 0, 1::integer-size(8)>> <> :binary.copy(<<0>>, 14)
      send(reader, {ref, {:ok, payload}})

      assert_receive {:device_data, ^payload}, 500
    end

    test "loops through multiple reads without dropping events" do
      {:ok, _pid} = start_transport()

      for n <- 1..5 do
        assert_receive {:fake_hid_read, reader, ref, 19}, 500
        payload = <<0x01, 0, 0, 0, n>> <> :binary.copy(<<0>>, 14)
        send(reader, {ref, {:ok, payload}})
        assert_receive {:device_data, ^payload}, 500
      end
    end

    test "stops the transport when the reader returns an error" do
      {:ok, pid} = start_transport()
      assert_receive {:fake_hid_read, reader, ref, 19}, 500
      mon = Process.monitor(pid)

      send(reader, {ref, {:error, :ebadf}})

      assert_receive {:DOWN, ^mon, :process, ^pid, {:reader_exited, {:shutdown, :ebadf}}},
                     500
    end
  end

  describe "write path" do
    test "write_output normalizes {:ok, n} -> :ok and records the payload" do
      {:ok, pid} = start_transport()
      assert_receive {:fake_hid_read, _, _, 19}

      payload = <<0x02, 0x07, 0x00, 0x00, 0::16>> <> :binary.copy(<<0xFF>>, 100)
      assert :ok = HidTransport.write_output(pid, payload)
      assert_receive {:fake_hid, {:write_output, ^payload}}
    end

    test "write_feature normalizes {:ok, n} -> :ok and records the payload" do
      {:ok, pid} = start_transport()
      assert_receive {:fake_hid_read, _, _, 19}

      payload = <<0x03, 0x08, 75>>
      assert :ok = HidTransport.write_feature(pid, payload)
      assert_receive {:fake_hid, {:write_feature, ^payload}}
    end
  end
end
