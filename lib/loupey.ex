defmodule Loupey do
  @moduledoc """
  A library for communicating with Loupedeck devices.
  """

  def start_link() do
    [device] = Circuits.UART.enumerate() |> Loupey.Device.discover_devices()
    Supervisor.start_link(
      [
        Loupey.Registry,
        {Loupey.DeviceHandler, {device, Loupey.Handler.ButtonController}}
      ],
      strategy: :one_for_one
    )
  end
end
