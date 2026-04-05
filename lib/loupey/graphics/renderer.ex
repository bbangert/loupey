defmodule Loupey.Graphics.Renderer do
  @moduledoc """
  Composites render instructions into device-native pixels via a Vix pipeline.

  The pipeline runs in stages:
  1. Background layer (solid color or gradient)
  2. Fill layer (partial region fill with direction)
  3. Icon layer (image composited onto background)
  4. Text layer (text rendered with font/position options)
  5. Format conversion (to control's pixel format)

  Each stage is a Vix operation — libvips chains them lazily so the entire
  composite is computed in a single pass.

  ## Render Instructions

  Render instructions are a map with optional keys:
  - `:background` — `"#RRGGBB"` solid color (default: `"#000000"`)
  - `:icon` — `Vix.Vips.Image.t()` already loaded icon image
  - `:fill` — `%{amount: 0..100, direction: :to_top | :to_bottom | :to_left | :to_right, color: "#RRGGBB"}`
  - `:text` — text rendering, either a simple string or a map with:
    - `:content` — the text string (required)
    - `:color` — text color (default: `"#FFFFFF"`)
    - `:font_size` — size in pixels (default: `16`)
    - `:align` — `:left`, `:center` (default), `:right`
    - `:valign` — `:top`, `:middle` (default), `:bottom`
    - `:orientation` — `:horizontal` (default) or `:vertical`

  Gradient support will be added in later milestones.
  """

  alias Loupey.Device.Control
  alias Loupey.Graphics.Format
  alias Vix.Vips.Operation

  @doc """
  Render a frame for a display control from render instructions.

  Returns device-native binary pixels ready for a `DrawBuffer` command.
  """
  @spec render_frame(map(), Control.t()) :: binary()
  def render_frame(instructions, %Control{display: display} = _control) do
    width = display.width
    height = display.height

    background_color = Map.get(instructions, :background, "#000000")

    Image.new!(width, height, color: background_color)
    |> apply_fill(instructions, width, height)
    |> apply_icon(instructions, width, height)
    |> apply_text(instructions, width, height)
    |> Image.flatten!()
    |> Format.to_device_format(display.pixel_format)
  end

  @doc """
  Render a solid color fill for a display control.

  Convenience function for the common case of filling a control with a single color.
  """
  @spec render_solid(Control.t(), term()) :: binary()
  def render_solid(%Control{display: display}, color) do
    Image.new!(display.width, display.height, color: color)
    |> Image.flatten!()
    |> Format.to_device_format(display.pixel_format)
  end

  # -- Pipeline stages --

  defp apply_fill(image, %{fill: fill}, width, height) do
    amount = Map.get(fill, :amount, 100)
    direction = Map.get(fill, :direction, :to_top)
    color = Map.get(fill, :color, "#FFFFFF")

    {fill_w, fill_h, x, y} = fill_rect(direction, amount, width, height)

    if fill_w > 0 and fill_h > 0 do
      fill_image = Image.new!(fill_w, fill_h, color: color)
      Image.compose!(image, fill_image, x: x, y: y)
    else
      image
    end
  end

  defp apply_fill(image, _instructions, _width, _height), do: image

  defp apply_icon(image, %{icon: icon}, width, height) when not is_nil(icon) do
    icon_w = Image.width(icon)
    icon_h = Image.height(icon)
    x = div(width - icon_w, 2)
    y = div(height - icon_h, 2)
    Image.compose!(image, icon, x: x, y: y)
  end

  defp apply_icon(image, _instructions, _width, _height), do: image

  defp apply_text(image, %{text: text}, width, height) when is_binary(text) do
    apply_text(image, %{text: %{content: text}}, width, height)
  end

  defp apply_text(image, %{text: %{content: content} = opts}, width, height) do
    color = Map.get(opts, :color, "#FFFFFF")
    font_size = Map.get(opts, :font_size, 16)

    case Image.Text.text(content, text_fill_color: color, font_size: font_size) do
      {:ok, text_img} ->
        text_img = maybe_rotate(text_img, Map.get(opts, :orientation, :horizontal))
        {x, y} = text_position(text_img, width, height, opts)
        Image.compose!(image, text_img, x: x, y: y)

      _ ->
        image
    end
  end

  defp apply_text(image, _instructions, _width, _height), do: image

  defp maybe_rotate(text_img, :vertical), do: Operation.rot!(text_img, :VIPS_ANGLE_D270)
  defp maybe_rotate(text_img, _), do: text_img

  defp text_position(text_img, width, height, opts) do
    text_w = Image.width(text_img)
    text_h = Image.height(text_img)

    x = align_x(Map.get(opts, :align, :center), width, text_w)
    y = align_y(Map.get(opts, :valign, :middle), height, text_h)

    {max(0, min(x, width - 1)), max(0, min(y, height - 1))}
  end

  defp align_x(:left, _width, _text_w), do: 2
  defp align_x(:right, width, text_w), do: width - text_w - 2
  defp align_x(_, width, text_w), do: div(width - text_w, 2)

  defp align_y(:top, _height, _text_h), do: 2
  defp align_y(:bottom, height, text_h), do: height - text_h - 2
  defp align_y(_, height, text_h), do: div(height - text_h, 2)

  defp fill_rect(:to_top, amount, width, height) do
    fill_h = round(height * amount / 100)
    {width, fill_h, 0, height - fill_h}
  end

  defp fill_rect(:to_bottom, amount, width, height) do
    fill_h = round(height * amount / 100)
    {width, fill_h, 0, 0}
  end

  defp fill_rect(:to_right, amount, width, height) do
    fill_w = round(width * amount / 100)
    {fill_w, height, 0, 0}
  end

  defp fill_rect(:to_left, amount, width, height) do
    fill_w = round(width * amount / 100)
    {fill_w, height, width - fill_w, 0}
  end
end
