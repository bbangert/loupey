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
  - `:icon` — either a `Vix.Vips.Image.t()` (already-materialized image)
    or a `String.t()` path resolved through `IconCache` at render time.
    Unresolvable paths drop the icon silently.
  - `:fill` — `%{amount: 0..100, direction: :to_top | :to_bottom | :to_left | :to_right, color: "#RRGGBB"}`
  - `:text` — text rendering, either a simple string or a map with:
    - `:content` — the text string (required)
    - `:color` — text color (default: `"#FFFFFF"`)
    - `:font_size` — size in pixels (default: `16`)
    - `:align` — `:left`, `:center` (default), `:right`
    - `:valign` — `:top`, `:middle` (default), `:bottom`
    - `:orientation` — `:horizontal` (default) or `:vertical`
  - `:transform` — apply geometric transform to a layer before compose:
    - `:target` — `:icon` (default) | `:text`
    - `:translate_x`, `:translate_y` — pixel offsets added at compose time
    - `:scale` — scalar multiplier (1.0 = identity), aspect-preserving
    - `:rotate` — degrees clockwise (90/180/270 fast-path; arbitrary angles
      via affine for icon/text)
    Multiple transforms may be passed via `:transforms` as a list of these maps.
  - `:overlay` — `"#RRGGBB"` or `"#RRGGBBAA"` color composited as a final
    full-region wash over the rendered frame (used by press_flash).

  Gradient support will be added in later milestones.
  """

  alias Loupey.Device.Control
  alias Loupey.Graphics.{Format, IconCache}
  alias Vix.Vips.Operation

  @doc """
  Render a frame for a display control from render instructions.

  Returns device-native binary pixels ready for a `DrawBuffer` command.
  """
  @spec render_frame(map(), Control.t()) :: binary()
  def render_frame(instructions, %Control{display: display} = _control) do
    width = display.width
    height = display.height

    instructions = maybe_load_icon(instructions, display)
    background_color = Map.get(instructions, :background, "#000000")

    {image, instructions} =
      Image.new!(width, height, color: background_color)
      |> apply_fill(instructions, width, height)
      |> apply_icon(instructions, width, height)

    image
    |> apply_text(instructions, width, height)
    |> apply_overlay(instructions, width, height)
    |> Image.flatten!()
    |> Format.to_device_format(display.pixel_format)
  end

  # Icon resolution — turn a string path into a thumbnailed Vix image
  # via the cache. Already-materialized `%Vix.Vips.Image{}` values pass
  # through. Unresolvable paths drop the `:icon` key so downstream
  # `apply_icon/4` skips compositing rather than crashing.
  #
  # Lives here (rather than per-caller) so both the direct render path
  # (LayoutEngine) and the per-tick animation path (Ticker) get
  # consistent behavior — and so adding a new render entry-point
  # doesn't have to remember to call it.
  defp maybe_load_icon(%{icon: path} = instructions, display) when is_binary(path) do
    has_text = Map.has_key?(instructions, :text)
    min_dim = min(display.width, display.height)
    # Leave room for text label at the bottom when text is present.
    max_dim = if has_text, do: round(min_dim * 0.65), else: min_dim - 4

    # `IconCache.lookup/2`'s guard requires `max_dim > 0` — a degenerate
    # display (or one nearly entirely consumed by a text label) would
    # otherwise crash the render path. Drop the icon entirely when
    # there's no usable space; a 1px thumbnail wouldn't render
    # meaningfully anyway.
    if max_dim > 0 do
      case IconCache.lookup(path, max_dim) do
        {:ok, img} -> %{instructions | icon: img}
        :error -> Map.delete(instructions, :icon)
      end
    else
      Map.delete(instructions, :icon)
    end
  end

  defp maybe_load_icon(instructions, _display), do: instructions

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

  defp apply_fill(image, %{fill: fill} = instructions, width, height) do
    amount = Map.get(fill, :amount, 100)
    direction = Map.get(fill, :direction, :to_top)
    color = Map.get(fill, :color, "#FFFFFF")

    {fill_w, fill_h, x, y} = fill_rect(direction, amount, width, height)

    image =
      if fill_w > 0 and fill_h > 0 do
        fill_image = Image.new!(fill_w, fill_h, color: color)
        Image.compose!(image, fill_image, x: x, y: y)
      else
        image
      end

    {image, instructions}
  end

  defp apply_fill(image, instructions, _width, _height), do: {image, instructions}

  defp apply_icon({image, instructions}, %{icon: icon} = _orig, width, height)
       when not is_nil(icon) do
    apply_icon_impl(image, instructions, icon, width, height)
  end

  defp apply_icon({image, instructions}, _orig, _width, _height), do: {image, instructions}

  defp apply_icon_impl(image, instructions, icon, width, height) do
    transform = transform_for(instructions, :icon)
    icon = transform_image(icon, transform)

    icon_w = Image.width(icon)
    icon_h = Image.height(icon)
    has_text = Map.has_key?(instructions, :text)

    x = div(width - icon_w, 2)

    y =
      if has_text do
        # Center icon in upper portion, leaving space for text below
        text_space = round(height * 0.25)
        div(height - text_space - icon_h, 2)
      else
        div(height - icon_h, 2)
      end

    {tx, ty} = transform_offsets(transform)
    compose_x = max(0, x + tx)
    compose_y = max(0, y + ty)

    # `:_icon_bottom` is read by `align_y(:bottom, ...)` to place text
    # directly under the icon. It must reflect the *clamped* y, not the
    # pre-clamp value — otherwise large negative `translate_y` clamped
    # to 0 here would still produce a stale icon-bottom calculation.
    instructions = Map.put(instructions, :_icon_bottom, compose_y + icon_h)

    {Image.compose!(image, icon, x: compose_x, y: compose_y), instructions}
  end

  defp apply_text(image, %{text: text} = instructions, width, height) when is_binary(text) do
    apply_text(image, %{instructions | text: %{content: text}}, width, height)
  end

  defp apply_text(image, %{text: %{content: content} = opts} = instructions, width, height) do
    color = Map.get(opts, :color) || "#FFFFFF"
    font_size = Map.get(opts, :font_size) || 16
    font_size = if is_binary(font_size), do: String.to_integer(font_size), else: font_size

    case Image.Text.text(content, text_fill_color: color, font_size: font_size) do
      {:ok, text_img} ->
        text_img = maybe_rotate(text_img, Map.get(opts, :orientation, :horizontal))
        text_transform = transform_for(instructions, :text)
        text_img = transform_image(text_img, text_transform)
        {x, y} = text_position(text_img, width, height, instructions, opts)
        {tx, ty} = transform_offsets(text_transform)
        text_w = Image.width(text_img)
        text_h = Image.height(text_img)
        # Re-clamp after the translate. `text_position/5` clamps to the
        # frame, but adding tx/ty after that can re-overflow. Clamp the
        # text image's top-left corner so the *transformed* text image
        # stays within the frame, not just its origin.
        max_x = max(0, width - text_w)
        max_y = max(0, height - text_h)
        final_x = max(0, min(x + tx, max_x))
        final_y = max(0, min(y + ty, max_y))
        Image.compose!(image, text_img, x: final_x, y: final_y)

      _ ->
        image
    end
  end

  defp apply_text(image, _instructions, _width, _height), do: image

  defp maybe_rotate(text_img, :vertical), do: Operation.rot!(text_img, :VIPS_ANGLE_D270)
  defp maybe_rotate(text_img, _), do: text_img

  defp text_position(text_img, width, height, instructions, opts) do
    text_w = Image.width(text_img)
    text_h = Image.height(text_img)
    icon_bottom = Map.get(instructions, :_icon_bottom)

    x = align_x(Map.get(opts, :align, :center), width, text_w)
    y = align_y(Map.get(opts, :valign, :middle), height, text_h, icon_bottom)

    {max(0, min(x, width - 1)), max(0, min(y, height - 1))}
  end

  defp align_x(:left, _width, _text_w), do: 2
  defp align_x(:right, width, text_w), do: width - text_w - 2
  defp align_x(_, width, text_w), do: div(width - text_w, 2)

  # When icon is present and text is at bottom, place text right below icon
  defp align_y(:bottom, _height, _text_h, icon_bottom) when is_integer(icon_bottom) do
    icon_bottom + 2
  end

  defp align_y(:top, _height, _text_h, _icon_bottom), do: 2
  defp align_y(:bottom, height, text_h, _icon_bottom), do: height - text_h - 2
  defp align_y(_, height, text_h, _icon_bottom), do: div(height - text_h, 2)

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

  # -- Transform & overlay --

  defp apply_overlay(image, %{overlay: color}, width, height) when is_binary(color) do
    {bg_hex, alpha} = parse_overlay_color(color)
    compose_overlay(image, bg_hex, alpha, width, height)
  end

  # Tween's RGB lerp returns `{r, g, b}` for 6-hex stops; without this
  # head, an animated overlay using two `"#RRGGBB"` strings would
  # silently no-op on every tick. Treat the tuple as fully opaque.
  defp apply_overlay(image, %{overlay: {r, g, b}}, width, height)
       when is_integer(r) and is_integer(g) and is_integer(b) do
    compose_overlay(image, rgb_to_hex({r, g, b}), 255, width, height)
  end

  defp apply_overlay(image, _instructions, _width, _height), do: image

  defp compose_overlay(image, bg_hex, alpha, width, height) do
    overlay =
      width
      |> Image.new!(height, color: bg_hex)
      |> add_alpha_band(alpha)

    Image.compose!(image, overlay, x: 0, y: 0)
  end

  defp rgb_to_hex({r, g, b}) do
    "#" <> hex2(r) <> hex2(g) <> hex2(b)
  end

  defp hex2(n) do
    n |> Integer.to_string(16) |> String.pad_leading(2, "0") |> String.upcase()
  end

  defp add_alpha_band(image, 255), do: image

  defp add_alpha_band(image, alpha) do
    {:ok, with_alpha} = Operation.bandjoin_const(image, [alpha * 1.0])
    with_alpha
  end

  defp parse_overlay_color("#" <> hex) when byte_size(hex) == 8 do
    <<bg::binary-size(6), a::binary-size(2)>> = hex
    {"#" <> bg, String.to_integer(a, 16)}
  end

  defp parse_overlay_color("#" <> _ = color), do: {color, 255}

  defp transform_for(instructions, target) do
    cond do
      transforms = Map.get(instructions, :transforms) ->
        Enum.find(transforms, &(Map.get(&1, :target, :icon) == target))

      transform = Map.get(instructions, :transform) ->
        if Map.get(transform, :target, :icon) == target, do: transform

      true ->
        nil
    end
  end

  defp transform_offsets(nil), do: {0, 0}

  defp transform_offsets(transform) do
    {round(Map.get(transform, :translate_x, 0)), round(Map.get(transform, :translate_y, 0))}
  end

  defp transform_image(image, nil), do: image

  defp transform_image(image, transform) do
    image
    |> apply_scale(Map.get(transform, :scale))
    |> apply_rotate(Map.get(transform, :rotate))
  end

  defp apply_scale(image, scale) when is_number(scale) and scale > 0 and scale != 1.0 do
    Operation.resize!(image, scale * 1.0)
  end

  defp apply_scale(image, _), do: image

  defp apply_rotate(image, nil), do: image
  defp apply_rotate(image, 0), do: image
  defp apply_rotate(image, 90), do: Operation.rot!(image, :VIPS_ANGLE_D90)
  defp apply_rotate(image, 180), do: Operation.rot!(image, :VIPS_ANGLE_D180)
  defp apply_rotate(image, 270), do: Operation.rot!(image, :VIPS_ANGLE_D270)

  defp apply_rotate(image, degrees) when is_number(degrees) do
    radians = degrees * :math.pi() / 180.0
    cos_a = :math.cos(radians)
    sin_a = :math.sin(radians)
    Operation.affine!(image, [cos_a, -sin_a, sin_a, cos_a])
  end
end
