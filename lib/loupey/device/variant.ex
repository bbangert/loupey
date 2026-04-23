defmodule Loupey.Device.Variant do
  @moduledoc """
  A behaviour for implementing device variant specific configuration and handling.
  """

  @doc """
  Check if this behaviour is the correct variant for the given device.
  """
  @callback is_variant?(device_info :: map) :: boolean

  @doc """
  Return a `Loupey.Device.Spec` describing this device's controls and capabilities.
  """
  @callback device_spec() :: Loupey.Device.Spec.t()

  @doc """
  Return a `Loupey.Device.Layout` describing the device's physical
  control positions for the profile editor UI. Optional — variants that
  do not implement this fall back to a row-stacked renderer.
  """
  @callback layout() :: Loupey.Device.Layout.t()

  @optional_callbacks layout: 0
end
