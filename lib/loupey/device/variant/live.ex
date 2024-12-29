defmodule Loupey.Device.Variant.Live do
  @behaviour Loupey.Device.Variant

  # A few common constants used.
  @key_size 90
  @columns 4
  @display_center_width 360
  @display_left_width 60
  @display_right_width 60

  @moduledoc """
  Variant specific configuration and handling for Loupedeck Live.
  """

  def is_variant?(device_info), do: match?(%{product_id: 0x0004, vendor_id: 0x2EC2}, device_info)

  def device_info() do
    %{
      type: "Loupedeck Live",
      key_size: @key_size,
      buttons: [0, 1, 2, 3, 4, 5, 6, 7],
      knobs: ["knobCL", "knobCR", "knobTL", "knobTR", "knobBL", "knobBR"],
      columns: @columns,
      rows: 3,
      displays: %{
        center: %{id: <<0x00, 0x4D>>, width: @display_center_width, height: 270, offset: {60, 0}},
        left: %{id: <<0x00, 0x4D>>, width: @display_left_width, height: 270},
        right: %{id: <<0x00, 0x4D>>, width: @display_right_width, height: 270, offset: {420, 0}}
      },
      visible_x: {0, 480}
    }
  end

  def touch_target(x, _y, _id) when x < @display_left_width, do: :left
  def touch_target(x, _y, _id) when x >= @display_left_width + @display_center_width, do: :right

  def touch_target(x, y, _id) do
    column = floor((x - @display_left_width) / @key_size)
    row = floor(y / @key_size)
    key = row * @columns + column
    {:center, key}
  end
end
