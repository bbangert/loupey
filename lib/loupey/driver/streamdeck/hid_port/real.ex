defmodule Loupey.Driver.Streamdeck.HidPort.Real do
  @moduledoc """
  Production `HidPort` backed by the `lawik/hid` NIF.

  Filters `HID.enumerate/0` results in Elixir because the upstream NIF's
  VID/PID args are ignored (see scratchpad).
  """

  @behaviour Loupey.Driver.Streamdeck.HidPort

  @impl true
  def enumerate, do: HID.enumerate()

  @impl true
  def open(path) when is_binary(path), do: HID.open(path)

  @impl true
  def close(handle), do: HID.close(handle)

  @impl true
  def read(handle, size), do: HID.read(handle, size)

  @impl true
  def write_output_report(handle, data), do: HID.write(handle, data)

  @impl true
  def write_feature_report(handle, data), do: HID.write_report(handle, data)
end
