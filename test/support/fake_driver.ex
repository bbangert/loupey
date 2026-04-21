defmodule Loupey.Driver.Fake do
  @moduledoc """
  Test driver that records calls by sending messages to the test process and
  lets tests inject synthetic `{:device_data, bytes}` messages into a
  `Loupey.DeviceServer` without any real transport.

  The `tty` passed to `DeviceServer.start_link/1` is the recorder pid — a
  pid (typically the test process) that will receive
  `{:fake_driver, :open | :close | {:send_command, encoded}}` tuples.

  Usage:

      {:ok, device_pid} =
        Loupey.DeviceServer.start_link(
          driver: Loupey.Driver.Fake,
          tty: self(),
          device_id: :fake1
        )

      assert_receive {:fake_driver, {:open, _}}

      Loupey.Driver.Fake.send_device_data(device_pid, <<1, 2, 3>>)

      Loupey.DeviceServer.render(:fake1, %Loupey.RenderCommands.SetBrightness{level: 0.5})
      assert_receive {:fake_driver, {:send_command, {0x99, "encoded"}}}
  """

  @behaviour Loupey.Driver

  alias Loupey.Device.{Control, Display, Spec}

  @doc "Inject a `{:device_data, bytes}` message into the DeviceServer."
  def send_device_data(device_pid, bytes) do
    send(device_pid, {:device_data, bytes})
  end

  # -- Driver behaviour --

  @impl true
  def device_spec do
    %Spec{
      type: "Fake",
      controls: [
        %Control{
          id: {:key, 0},
          capabilities: MapSet.new([:press, :display]),
          display: %Display{
            width: 10,
            height: 10,
            pixel_format: :rgb565,
            offset: {0, 0},
            display_id: <<0x00>>
          }
        }
      ]
    }
  end

  @impl true
  def matches?(_info), do: false

  @impl true
  def open(recorder, opts) when is_pid(recorder) do
    send(recorder, {:fake_driver, {:open, opts}})
    {:ok, recorder}
  end

  @impl true
  def close(recorder) do
    send(recorder, {:fake_driver, :close})
    :ok
  end

  @impl true
  def send_command(recorder, encoded) do
    send(recorder, {:fake_driver, {:send_command, encoded}})
    :ok
  end

  @impl true
  def parse(driver_state, _bytes), do: {driver_state, []}

  @impl true
  def encode(_cmd), do: {0x99, "encoded"}

  @impl true
  def encode_refresh(display_id), do: {0x9A, display_id}
end
