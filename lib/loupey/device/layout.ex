defmodule Loupey.Device.Layout do
  @moduledoc """
  UI-only physical layout description for a device variant.

  Provides pixel coordinates and shapes for each control so the profile
  editor can render a visual representation that matches the device's
  actual physical layout (knobs flanking a display, press-only buttons
  below, etc.) rather than an approximate row-stacked grid.

  Layouts live alongside (not inside) `Loupey.Device.Spec` because the
  spec is consumed by drivers, encoders, parsers, and touch resolution
  — none of which need layout pixels. `Display.offset` already provides
  render-target positioning for controls that draw pixels; `Layout`
  covers knobs and press-only buttons, which have no `Display`.

  A variant opts in by implementing the optional `layout/0` callback on
  `Loupey.Device.Variant`. Variants without a layout fall back to the
  row-stacked renderer in `LoupeyWeb.DeviceGrid`.
  """

  alias Loupey.Device.Control

  @type shape :: :square | :round | :rect | :pill

  @type position :: %{
          x: non_neg_integer(),
          y: non_neg_integer(),
          width: pos_integer(),
          height: pos_integer(),
          shape: shape()
        }

  @type t :: %__MODULE__{
          face_width: pos_integer(),
          face_height: pos_integer(),
          positions: %{Control.id() => position()}
        }

  @enforce_keys [:face_width, :face_height, :positions]
  defstruct [:face_width, :face_height, :positions]
end
