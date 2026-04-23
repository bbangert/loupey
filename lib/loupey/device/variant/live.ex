defmodule Loupey.Device.Variant.Live do
  @behaviour Loupey.Device.Variant

  alias Loupey.Device.{Control, Display, Layout, Spec}

  @key_size 90
  @columns 4
  @rows 3
  @display_left_width 60
  @display_right_width 60
  @display_height 270
  @display_id <<0x00, 0x4D>>

  # Editor-UI layout coordinates. Abstract pixels — DeviceGrid scales the
  # whole face with CSS transform, so these only need to be self-consistent.
  # Proportions chosen to match the physical Loupedeck Live photo: ~120 px
  # knob gutter on each side of the 480 px display, ~120 px top margin above
  # the display for the Loupedeck-branded chassis, and 8 round buttons
  # spanning the full face width below the display.
  @face_width 720
  @face_height 600
  @display_face_x 120
  @display_face_y 120
  @knob_size 60
  @knob_x_left div(@display_face_x - @knob_size, 2)
  @knob_x_right @face_width - @knob_x_left - @knob_size
  # Knobs align vertically with the three key rows. Center each knob on
  # its row's mid-y (row center = display_y + row*90 + 45).
  @knob_row_ys [
    @display_face_y + 45 - div(@knob_size, 2),
    @display_face_y + 135 - div(@knob_size, 2),
    @display_face_y + 225 - div(@knob_size, 2)
  ]
  @button_size 54
  # Buttons sit below the display with a small gap.
  @button_y @display_face_y + @display_height + 30
  # Eight buttons — first and last centers align with the left and right
  # knob columns. Span = knob_right_center − knob_left_center = 600, so
  # pitch = round(600 / 7) ≈ 86.
  @button_pitch 86

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
  def layout do
    positions =
      knob_positions()
      |> Map.merge(strip_positions())
      |> Map.merge(key_positions())
      |> Map.merge(button_positions())

    %Layout{
      face_width: @face_width,
      face_height: @face_height,
      positions: positions
    }
  end

  @impl true
  def device_spec do
    %Spec{
      type: "Loupedeck Live",
      controls:
        knob_controls() ++
          button_controls() ++ key_controls() ++ strip_controls()
    }
  end

  # -- Control definitions --

  defp knob_controls do
    knobs = [:knob_tl, :knob_cl, :knob_bl, :knob_tr, :knob_cr, :knob_br]

    Enum.map(knobs, fn id ->
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

  # -- Layout position helpers --

  defp knob_positions do
    [top, center, bottom] = @knob_row_ys

    %{
      :knob_tl => knob_at(@knob_x_left, top),
      :knob_cl => knob_at(@knob_x_left, center),
      :knob_bl => knob_at(@knob_x_left, bottom),
      :knob_tr => knob_at(@knob_x_right, top),
      :knob_cr => knob_at(@knob_x_right, center),
      :knob_br => knob_at(@knob_x_right, bottom)
    }
  end

  defp knob_at(x, y),
    do: %{x: x, y: y, width: @knob_size, height: @knob_size, shape: :round}

  defp strip_positions do
    %{
      :left_strip => %{
        x: @display_face_x,
        y: @display_face_y,
        width: @display_left_width,
        height: @display_height,
        shape: :rect
      },
      :right_strip => %{
        x: @display_face_x + @display_left_width + @columns * @key_size,
        y: @display_face_y,
        width: @display_right_width,
        height: @display_height,
        shape: :rect
      }
    }
  end

  defp key_positions do
    for row <- 0..(@rows - 1), col <- 0..(@columns - 1), into: %{} do
      key = row * @columns + col
      x = @display_face_x + @display_left_width + col * @key_size
      y = @display_face_y + row * @key_size
      {{:key, key}, %{x: x, y: y, width: @key_size, height: @key_size, shape: :square}}
    end
  end

  defp button_positions do
    # Button 0 center = left knob column center; pitch spaces the
    # remaining 7 so that button 7 center lands on the right knob column.
    knob_center_x = @knob_x_left + div(@knob_size, 2)
    button_x_first = knob_center_x - div(@button_size, 2)

    for i <- 0..7, into: %{} do
      x = button_x_first + i * @button_pitch

      {{:button, i},
       %{x: x, y: @button_y, width: @button_size, height: @button_size, shape: :round}}
    end
  end
end
