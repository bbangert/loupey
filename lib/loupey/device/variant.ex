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
  Determine touch target based on x, y position and id.
  """
  @callback touch_target(x :: integer, y :: integer, id :: integer) ::
              {:center, integer} | {:left} | {:right} | {:knob} | {:not_visible}
end
