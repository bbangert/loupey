defmodule Loupey.Device do
  @moduledoc """
  Device data and command parsing and creation.

  This module is responsible for identifying devices, parsing incoming messages, and
  creating commands to send to the device based on device specific information.
  """

  use TypedStruct

  typedstruct enforce: true do
    @typedoc """
    A struct representing a Loupedeck device tty, its variant, variant info, and touch state.
    """
    field(:tty, String.t())
    field(:variant, module())
    field(:variant_info, map())
    field(:touches, touch_map())
  end

  @type knob() :: :knobCT | :knobTL | :knobCL | :knobBL | :knobTR | :knobCR | :knobBR
  @type transaction_id() :: integer()
  @type touch_id() :: integer()
  @type x_coord() :: integer()
  @type y_coord() :: integer()
  @type button_number() :: integer()
  @type location :: :left | {:center, button_number()} | :right
  @type touch() :: {x_coord(), y_coord(), touch_id(), location()}
  @type touch_map() :: %{touch_id() => touch()}

  @type parsed_command() ::
          {:unknown_command | :unknown_message, binary()}
          | {:unknown_command, transaction_id(), binary()}
          | {:button_press, integer(), :down | :up}
          | {:knob_rotate, knob(), :left | :right}
          | {:touch_start | :touch_move | :touch_end, touch_map(), touch()}

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

  @type push_buttons ::
          :knobCT
          | :knobTL
          | :knobCL
          | :knobBL
          | :knobTR
          | :knobCR
          | :knobBR
          | 0
          | 1
          | 2
          | 3
          | 4
          | 5
          | 6
          | 7
          | :home
          | :undo
          | :keyboard
          | :enter
          | :save
          | :fnL
          | :a
          | :c
          | :fnR
          | :b
          | :d
          | :e

  @type color_buttons() :: 0..7

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

  # General device desicovery and identification.

  @doc """
  Discover devices from a list of device tty's and device info such as
  `Circuits.UART.enumerate/0` returns and return a list of `Loupey.Device` structs
  that were found.
  """
  @spec discover_devices(map()) :: list(Loupey.Device.t())
  def discover_devices(device_list) do
    device_list
    |> Enum.map(&find_variant/1)
    |> Enum.reject(&is_nil/1)
  end

  defp find_variant({tty, device_info}) do
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

  # Command parsing.

  @doc """
  Parse a message from a Loupedeck device and return the device and the parsed message.
  """
  @spec parse_message(Loupey.Device.t(), nonempty_binary()) ::
          {Loupey.Device.t(), parsed_command()}
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

  def parse_message(device, payload), do: {device, {:unknown_message, payload}}

  defp parse_command(command) do
    case Enum.find(@commands, fn {_, value} -> value == command end) do
      {command, _} -> command
      nil -> :unknown_command
    end
  end

  defp parse_knob_rotate(data) do
    case data do
      <<id, delta>> -> {:knob_rotate, button_lookup(id), if(delta == 1, do: :right, else: :left)}
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

  # Command creation.
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

  @type command() :: {non_neg_integer(), nonempty_binary() | non_neg_integer()}

  @doc """
  Create a command to fill a key with a color.
  """
  @spec fill_key_color_command(Loupey.Device.t(), {:center, button_number()}, String.t()) ::
          command()
  def fill_key_color_command(device, {:center, index}, color) do
    pixel_count = device.variant_info.key_size * device.variant_info.key_size
    buffer = Loupey.Color.fill_key_color(color, pixel_count)
    key_size = device.variant_info.key_size
    {x, y} = find_key_offset(device, index)
    draw_buffer_command(device, {:center, key_size, key_size, x, y}, buffer)
  end

  defp find_key_offset(device, button_id) do
    {x, _} = device.variant_info.visible_x
    key_size = device.variant_info.key_size
    x = x + rem(button_id, device.variant_info.columns) * key_size
    y = floor(button_id / device.variant_info.columns) * key_size
    {x, y}
  end

  @doc """
  Create a command to fill a slider with a color.
  """
  @spec fill_slider_color_command(
          Loupey.Device.t(),
          :left | :right,
          String.t(),
          non_neg_integer()
        ) :: command()
  def fill_slider_color_command(device, location, color, percent) do
    display = Map.fetch!(device.variant_info.displays, location)
    buffer = Loupey.Color.fill_slider_color(color, display.width, display.height, percent)
    draw_buffer_command(device, {location, display.width, display.height, 0, 0}, buffer)
  end

  @doc """
  Create a command to set the brightness of the device.
  """
  @spec set_brightness_command(number()) :: command()
  def set_brightness_command(value) do
    byte = max(0, min(@max_brightness, round(value * @max_brightness)))
    {@commands.set_brightness, byte}
  end

  @doc """
  Create a command to set the color of a button.
  """
  @spec set_button_color_command(color_buttons(), String.t()) :: command()
  def set_button_color_command(id, color_value) do
    [r, g, b] = Loupey.Color.parse_color(color_value)
    {@commands.set_color, <<Map.fetch!(@buttons, id), r, g, b>>}
  end

  @doc """
  Create a command to draw a buffer to a display.
  """
  @spec draw_buffer_command(
          Loupey.Device.t(),
          {:left | :right | :center, integer(), integer(), integer(), integer()},
          binary()
        ) :: command()
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

  @spec draw_image_command(Loupey.Device.t(), button_number(), Loupey.Image.t()) :: command()
  def draw_image_command(device, button_id, image) do
    {x, y} = find_key_offset(device, button_id)
    # Center the image if it is smaller than the key size.
    offset_x =
      case image.width < 90 do
        true -> round((device.variant_info.key_size - image.width) / 2)
        false -> 0
      end

    offset_y =
      case image.height < 90 do
        true -> round((device.variant_info.key_size - image.height) / 2)
        false -> 0
      end

    draw_buffer_command(
      device,
      {:center, image.width, image.height, x + offset_x, y + offset_y},
      image.data
    )
  end

  @doc """
  Create a command to refresh a display.
  """
  @spec refresh_command(Loupey.Device.t(), :left | :center | :right) :: command()
  def refresh_command(device, id) do
    display = Map.fetch!(device.variant_info.displays, id)
    {@commands.draw, display.id}
  end

  defp button_lookup(id) do
    case Enum.find(@buttons, fn {_, value} -> value == id end) do
      {button, _} -> button
      nil -> nil
    end
  end
end
