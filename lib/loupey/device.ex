defmodule Loupey.Device do
  defstruct [:tty, :variant, :variant_info, :touches]

  @variants [
    Loupey.Device.Variant.Live
  ]

  @max_brightness 10

  @commands %{
    button_press: 0x00,
    knob_rotate: 0x01,
    set_color: 0x02,
    serial: 0x03,
    reset: 0x06,
    version: 0x07,
    set_brightness: 0x09,
    framebuff: 0x10,
    set_vibration: 0x1B,
    mcu: 0x0D,
    draw: 0x0F,
    touch: 0x4D,
    touch_ct: 0x52,
    touch_end: 0x6D,
    touch_end_ct: 0x72
  }

  @buttons %{
    :knobCT => 0x00,
    :knobTL => 0x01,
    :knobCL => 0x02,
    :knobBL => 0x03,
    :knobTR => 0x04,
    :knobCR => 0x05,
    :knobBR => 0x06,
    0 => 0x07,
    1 => 0x08,
    2 => 0x09,
    3 => 0x0A,
    4 => 0x0B,
    5 => 0x0C,
    6 => 0x0D,
    7 => 0x0E,
    :home => 0x0F,
    :undo => 0x10,
    :keyboard => 0x11,
    :enter => 0x12,
    :save => 0x13,
    :fnL => 0x14,
    :a => 0x15,
    :c => 0x16,
    :fnR => 0x17,
    :b => 0x18,
    :d => 0x19,
    :e => 0x1A
  }

  def discover_devices(device_list) do
    device_list
    |> Enum.map(&find_variant/1)
    |> Enum.reject(&is_nil/1)
  end

  def find_variant({tty, device_info}) do
    variant = Enum.find(@variants, & &1.is_variant?(device_info))

    case variant do
      nil ->
        nil

      variant ->
        %Loupey.Device{
          tty: tty,
          variant: variant,
          variant_info: variant.device_info(),
          touches: %{}
        }
    end
  end

  def parse_message(device, <<_, command, transaction_id, data::binary>>) do
    cmd = parse_command(command)

    case cmd do
      :button_press -> {device, parse_button_press(data)}
      :knob_rotate -> {device, parse_knob_rotate(data)}
      :touch -> parse_touch(device, {:touch, data})
      :touch_end -> parse_touch(device, {:touch_end, data})
      _ -> {device, {cmd, transaction_id, data}}
    end
  end

  def parse_message(_device, payload), do: {:unknown_message, payload}

  defp parse_command(command) do
    case Enum.find(@commands, fn {_, value} -> value == command end) do
      {command, _} -> command
      nil -> :unknown_command
    end
  end

  defp parse_knob_rotate(data) do
    case data do
      <<id, delta>> -> {:knob_rotate, button_lookup(id), delta}
      _ -> {:unknown_command, data}
    end
  end

  defp parse_button_press(data) do
    case data do
      <<id, 0x00>> -> {:button_press, button_lookup(id), :down}
      <<id, _>> -> {:button_press, button_lookup(id), :up}
      _ -> {:unknown_command, data}
    end
  end

  defp parse_touch(device, {command, data}) do
    case data do
      <<_, x::unsigned-big-integer-16, y::unsigned-big-integer-16, id>> ->
        touch = {x, y, id, device.variant.touch_target(x, y, id)}

        command =
          case command do
            :touch_end -> :touch_end
            _ when is_map_key(device.touches, id) -> :touch_move
            _ -> :touch_start
          end

        device =
          case command do
            :touch_end -> put_in(device.touches, Map.delete(device.touches, id))
            _ -> put_in(device.touches, Map.put(device.touches, id, touch))
          end

        {device, {command, device.touches, touch}}

      _ ->
        {device, {:unknown_command, data}}
    end
  end

  def key_pixels(device, location) do
    case location do
      :left ->
        display = device.variant_info.displays.left
        display.width * display.height

      {:center, _} ->
        device.variant_info.key_size * device.variant_info.key_size

      :right ->
        display = device.variant_info.displays.right
        display.width * display.height

      _ ->
        0
    end
  end

  def button_lookup(id) do
    case Enum.find(@buttons, fn {_, value} -> value == id end) do
      {button, _} -> button
      nil -> nil
    end
  end

  def fill_key_color_command(device, {location, index} = id, color) do
    pixel_count = key_pixels(device, id)
    buffer = Loupey.Image.fill_key_color(color, pixel_count)
    {x, _} = device.variant_info.visible_x
    key_size = device.variant_info.key_size
    x = x + rem(index, device.variant_info.columns) * key_size
    y = floor(index / device.variant_info.columns) * key_size
    draw_buffer_command(device, {location,  key_size, key_size, x, y}, buffer)
  end

  def fill_slider_color_command(device, location, color, percent) do
    display = Map.fetch!(device.variant_info.displays, location)
    buffer = Loupey.Image.fill_slider_color(color, display.width, display.height, percent)
    draw_buffer_command(device, {location, display.width, display.height, 0, 0}, buffer)
  end

  def set_brightness_command(value) do
    byte = max(0, min(@max_brightness, round(value * @max_brightness)))
    {@commands.set_brightness, byte}
  end

  def set_button_color_command(id, {r, g, b}) do
    {@commands.set_color, <<Map.fetch!(@buttons, id), r, g, b>>}
  end

  def draw_buffer_command(device, {id, width, height, x, y}, buffer) do
    display = Map.fetch!(device.variant_info.displays, id)

    {x, y} =
      case Map.get(display, :offset) do
        nil -> {x, y}
        {x_offset, y_offset} -> {x + x_offset, y + y_offset}
      end

    header = <<x::16, y::16, width::16, height::16>>
    {@commands.framebuff, <<display.id::binary, header::binary, buffer::binary>>}
  end

  def refresh_command(device, id) do
    display = Map.fetch!(device.variant_info.displays, id)
    {@commands.draw, display.id}
  end
end
