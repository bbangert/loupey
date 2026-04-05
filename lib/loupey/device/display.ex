defmodule Loupey.Device.Display do
  @moduledoc """
  Display properties for a control with the `:display` capability.

  Describes the pixel dimensions, format, and physical position of a
  renderable surface on a device.
  """

  @type pixel_format :: :rgb565 | :rgb888 | :jpeg
  @type t :: %__MODULE__{
          width: pos_integer(),
          height: pos_integer(),
          pixel_format: pixel_format(),
          offset: {non_neg_integer(), non_neg_integer()} | nil,
          display_id: binary() | nil
        }

  @enforce_keys [:width, :height, :pixel_format]
  defstruct [:width, :height, :pixel_format, :offset, :display_id]
end
