defmodule Loupey.Animation.Tween do
  @moduledoc """
  Pure interpolation primitives for the animation system.

  - Iteration math: given an elapsed time and a duration, compute
    which iteration we're on and the progress through it.
  - Direction handling: `:normal | :reverse | :alternate |
    :alternate_reverse`.
  - Color/number lerps and a keyframe lerp helper that picks the right
    surrounding stop pair and interpolates within it.
  """

  @type rgb :: {0..255, 0..255, 0..255}
  @type direction :: :normal | :reverse | :alternate | :alternate_reverse
  @type iterations :: pos_integer() | :infinite

  @doc """
  Given `elapsed_ms`, a per-iteration `duration_ms`, and a total
  `iterations` count (or `:infinite`), return the current iteration
  index (0-based) and the progress within it (`0.0..1.0`), or `:done`
  if all iterations have completed.

  `duration_ms` must be a positive integer; the iteration math doesn't
  support zero-duration animations (those should be handled as
  one-shots at the call site).
  """
  @spec iteration_and_progress(integer(), pos_integer(), iterations()) ::
          {non_neg_integer(), float()} | :done
  def iteration_and_progress(elapsed_ms, duration_ms, _iterations)
      when elapsed_ms <= 0 and duration_ms > 0 do
    {0, 0.0}
  end

  def iteration_and_progress(elapsed_ms, duration_ms, :infinite) when duration_ms > 0 do
    iter = div(elapsed_ms, duration_ms)
    progress = rem(elapsed_ms, duration_ms) / duration_ms
    {iter, progress}
  end

  def iteration_and_progress(elapsed_ms, duration_ms, iterations)
      when duration_ms > 0 and is_integer(iterations) and iterations > 0 do
    total = duration_ms * iterations

    if elapsed_ms >= total do
      :done
    else
      iter = div(elapsed_ms, duration_ms)
      progress = rem(elapsed_ms, duration_ms) / duration_ms
      {iter, progress}
    end
  end

  @doc """
  Apply a CSS animation-direction to a raw progress value.

  `:normal` returns progress as-is. `:reverse` flips it. `:alternate`
  reverses on odd iterations (so it bounces 0→1, 1→0, 0→1, ...).
  `:alternate_reverse` reverses on even iterations (1→0, 0→1, ...).
  """
  @spec apply_direction(float(), non_neg_integer(), direction()) :: float()
  def apply_direction(progress, _iter, :normal), do: progress
  def apply_direction(progress, _iter, :reverse), do: 1.0 - progress

  def apply_direction(progress, iter, :alternate) do
    if rem(iter, 2) == 0, do: progress, else: 1.0 - progress
  end

  def apply_direction(progress, iter, :alternate_reverse) do
    if rem(iter, 2) == 0, do: 1.0 - progress, else: progress
  end

  @doc """
  Linear interpolation between two RGB triples. `t` is clamped to
  `[0, 1]`. Result components are integers in `0..255`.
  """
  @spec lerp_rgb(rgb(), rgb(), float()) :: rgb()
  def lerp_rgb({r1, g1, b1}, {r2, g2, b2}, t) do
    t = clamp01(t)

    {
      round(r1 + (r2 - r1) * t),
      round(g1 + (g2 - g1) * t),
      round(b1 + (b2 - b1) * t)
    }
  end

  @doc """
  Linear interpolation between two numbers. `t` is clamped to `[0, 1]`.
  Returns a float.
  """
  @spec lerp_number(number(), number(), float()) :: float()
  def lerp_number(a, b, t) do
    t = clamp01(t)
    a + (b - a) * t * 1.0
  end

  @doc """
  Parse `"#RRGGBB"` into an `{r, g, b}` tuple. Tuples are used (rather
  than `Color.parse/1`'s list form) because the lerp pipeline benefits
  from the fixed-arity shape.
  """
  @spec parse_color(String.t()) :: rgb()
  def parse_color("#" <> hex) when byte_size(hex) == 6 do
    <<r::binary-size(2), g::binary-size(2), b::binary-size(2)>> = hex
    {hex_to_int(r), hex_to_int(g), hex_to_int(b)}
  end

  # `#RRGGBBAA` form used by overlay colors. Always returns a 4-tuple;
  # 6-hex inputs are widened to alpha=255 by `parse_rgba/1`.
  defp parse_rgba("#" <> hex) when byte_size(hex) == 6 do
    {r, g, b} = parse_color("#" <> hex)
    {r, g, b, 255}
  end

  defp parse_rgba("#" <> hex) when byte_size(hex) == 8 do
    <<r::binary-size(2), g::binary-size(2), b::binary-size(2), a::binary-size(2)>> = hex
    {hex_to_int(r), hex_to_int(g), hex_to_int(b), hex_to_int(a)}
  end

  defp hex_to_int(hex), do: String.to_integer(hex, 16)

  defp hex2(n) do
    n |> Integer.to_string(16) |> String.pad_leading(2, "0") |> String.upcase()
  end

  defp encode_rgba(r, g, b, a), do: "#" <> hex2(r) <> hex2(g) <> hex2(b) <> hex2(a)

  @doc """
  Interpolate within a sorted list of `{stop_pct, value_map}` keyframes.

  `progress` is in `[0.0, 1.0]`. Returns the interpolated value map by
  finding the surrounding stops and lerping each property between them.
  Properties present in only one stop are passed through unchanged at
  that stop boundary.

  Numeric values lerp via `lerp_number/3`; `"#RRGGBB"` strings lerp via
  `lerp_rgb/3` and are returned as `{r, g, b}` tuples; everything else
  steps (takes the lower stop's value until exactly at the upper stop).
  """
  @spec lerp_keyframe([{number(), map()}], float()) :: map()
  def lerp_keyframe(stops, progress) do
    progress = clamp01(progress)
    sorted = Enum.sort_by(stops, &elem(&1, 0))
    {lower_pct, lower_map, upper_pct, upper_map} = surrounding(sorted, progress * 100.0)

    cond do
      lower_pct == upper_pct ->
        lower_map

      true ->
        local_t = (progress * 100.0 - lower_pct) / (upper_pct - lower_pct)

        Map.new(Map.keys(Map.merge(lower_map, upper_map)), fn key ->
          lower_val = Map.get(lower_map, key)
          upper_val = Map.get(upper_map, key)
          {key, lerp_value(lower_val, upper_val, local_t)}
        end)
    end
  end

  defp surrounding([{pct, map}], _t), do: {pct, map, pct, map}

  defp surrounding([{p1, m1}, {p2, m2} | rest], t) do
    cond do
      t <= p1 -> {p1, m1, p1, m1}
      t <= p2 -> {p1, m1, p2, m2}
      rest == [] -> {p2, m2, p2, m2}
      true -> surrounding([{p2, m2} | rest], t)
    end
  end

  defp lerp_value(nil, b, _t), do: b
  defp lerp_value(a, nil, _t), do: a

  defp lerp_value(a, b, t) when is_number(a) and is_number(b) do
    lerp_number(a, b, t)
  end

  # If either side carries an alpha byte (8-hex), preserve the alpha
  # channel and return a string — `apply_overlay` only consumes
  # `"#RRGGBBAA"` strings, so a tuple here would silently no-op the
  # overlay stage.
  defp lerp_value("#" <> a_hex = a, "#" <> b_hex = b, t)
       when byte_size(a_hex) == 8 or byte_size(b_hex) == 8 do
    {r1, g1, bl1, al1} = parse_rgba(a)
    {r2, g2, bl2, al2} = parse_rgba(b)
    t = clamp01(t)

    encode_rgba(
      round(r1 + (r2 - r1) * t),
      round(g1 + (g2 - g1) * t),
      round(bl1 + (bl2 - bl1) * t),
      round(al1 + (al2 - al1) * t)
    )
  end

  defp lerp_value("#" <> _ = a, "#" <> _ = b, t) do
    lerp_rgb(parse_color(a), parse_color(b), t)
  end

  defp lerp_value({_, _, _} = a, {_, _, _} = b, t) do
    lerp_rgb(a, b, t)
  end

  defp lerp_value(a, b, t) when is_map(a) and is_map(b) do
    a
    |> Map.merge(b)
    |> Map.keys()
    |> Map.new(fn key -> {key, lerp_value(Map.get(a, key), Map.get(b, key), t)} end)
  end

  defp lerp_value(a, b, t) do
    if t >= 1.0, do: b, else: a
  end

  defp clamp01(t) when t <= 0.0, do: 0.0
  defp clamp01(t) when t >= 1.0, do: 1.0
  defp clamp01(t), do: t * 1.0
end
