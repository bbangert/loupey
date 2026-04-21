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
end
