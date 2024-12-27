defmodule Loupey do
  @moduledoc """
  A library for communicating with Loupedeck devices.
  """

  def start() do
    [device] = Circuits.UART.enumerate() |> Loupey.Device.discover_devices()
    Loupey.DeviceHandler.start_link({device, Loupey.Handler.Default})
  end
end
