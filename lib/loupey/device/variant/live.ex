defmodule Loupey.Device.Variant.Live do
  @behaviour Loupey.Device.Variant

  alias Loupey.Device.{Control, Display, Spec}

  @key_size 90
  @columns 4
  @rows 3
  @display_center_width 360
  @display_left_width 60
  @display_right_width 60
  @display_height 270
  @display_id <<0x00, 0x4D>>

  @moduledoc """
  Variant specific configuration and handling for Loupedeck Live.

  Physical layout (480x270 pixels):
  ```
  ┌──────┬────────────────────────┬──────┐
  │ Left │       Center           │Right │
  │ 60px │       360px            │ 60px │
  │ 270px│  4×3 grid of 90px keys│270px │
  └──────┴────────────────────────┴──────┘
  ```
  """

  @impl true
  def is_variant?(device_info), do: match?(%{product_id: 0x0004, vendor_id: 0x2EC2}, device_info)

  @impl true
  def device_spec do
    %Spec{
      type: "Loupedeck Live",
      controls:
        knob_controls() ++
          button_controls() ++ key_controls() ++ strip_controls() ++ misc_button_controls()
    }
  end

  @impl true
  def touch_target(x, _y, _id) when x < @display_left_width, do: :left
  def touch_target(x, _y, _id) when x >= @display_left_width + @display_center_width, do: :right

  def touch_target(x, y, _id) do
    column = floor((x - @display_left_width) / @key_size)
    row = floor(y / @key_size)
    key = row * @columns + column
    {:center, key}
  end

  # -- Control definitions --

  defp knob_controls do
    knobs = [
      {:knob_ct, 0x00},
      {:knob_tl, 0x01},
      {:knob_cl, 0x02},
      {:knob_bl, 0x03},
      {:knob_tr, 0x04},
      {:knob_cr, 0x05},
      {:knob_br, 0x06}
    ]

    Enum.map(knobs, fn {id, _hw_id} ->
      %Control{id: id, capabilities: MapSet.new([:rotate, :press])}
    end)
  end

  defp button_controls do
    Enum.map(0..7, fn i ->
      %Control{id: {:button, i}, capabilities: MapSet.new([:press, :led])}
    end)
  end

  defp key_controls do
    for row <- 0..(@rows - 1), col <- 0..(@columns - 1) do
      key = row * @columns + col
      x_offset = @display_left_width + col * @key_size
      y_offset = row * @key_size

      %Control{
        id: {:key, key},
        capabilities: MapSet.new([:touch, :display]),
        display: %Display{
          width: @key_size,
          height: @key_size,
          pixel_format: :rgb565,
          offset: {x_offset, y_offset},
          display_id: @display_id
        }
      }
    end
  end

  defp strip_controls do
    [
      %Control{
        id: :left_strip,
        capabilities: MapSet.new([:touch, :display]),
        display: %Display{
          width: @display_left_width,
          height: @display_height,
          pixel_format: :rgb565,
          offset: {0, 0},
          display_id: @display_id
        }
      },
      %Control{
        id: :right_strip,
        capabilities: MapSet.new([:touch, :display]),
        display: %Display{
          width: @display_right_width,
          height: @display_height,
          pixel_format: :rgb565,
          offset: {420, 0},
          display_id: @display_id
        }
      }
    ]
  end

  defp misc_button_controls do
    misc = [:home, :undo, :keyboard, :enter, :save, :fn_l, :a, :c, :fn_r, :b, :d, :e]

    Enum.map(misc, fn id ->
      %Control{id: id, capabilities: MapSet.new([:press])}
    end)
  end
end
