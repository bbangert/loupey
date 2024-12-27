defmodule Loupey.Device.Variant do
  @moduledoc """
  A behaviour for implementing device variant specific configuration and handling.
  """

  @doc """
  Check if this behaviour is the correct variant for the given device.
  """
  @callback is_variant?(device_info :: map) :: boolean

  @doc """
  Return variant specific device information. This method should return a map with the following
  keys:

  * `:type` - The type of device this variant is.
  * `:key_size` - The size of the key in pixels.
  * `:buttons` - A list of the buttons this variant has.
  * `:knobs` - A list of the knobs this variant has.
  * `:columns` - The number of columns of buttons this variant has.
  * `:rows` - The number of rows of buttons this variant has.
  * `:displays` - A map of the displays with their id, width, height, and optionally offset.
  * `:visible_x` - Tuple of x, y of the visible button.

  """
  @callback device_info() :: map

  @doc """
  Determine touch target based on x, y position and id.
  """
  @callback touch_target(x :: integer, y :: integer, id :: integer) ::
              {:center, integer} | {:left} | {:right} | {:knob} | {:not_visible}
end
