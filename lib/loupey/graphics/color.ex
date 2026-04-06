defmodule Loupey.Graphics.Color do
  @moduledoc """
  Color parsing, conversion, and gamma correction for device rendering.
  """

  import Bitwise

  # Gamma correction to compensate for LCD panels rendering darker than sRGB monitors.
  # Applied before RGB565 quantization. Lower values = brighter output.
  @gamma_correction 0.85

  @doc """
  Parse a hex color string "#RRGGBB" into `[r, g, b]` integers.
  """
  @spec parse(String.t()) :: [integer(), ...]
  def parse("#" <> hex) do
    hex
    |> String.codepoints()
    |> Enum.chunk_every(2)
    |> Enum.map(&(&1 |> Enum.join() |> String.to_integer(16)))
  end

  @doc """
  Convert an `[r, g, b]` list to a single RGB565 little-endian binary.
  Applies gamma correction before quantization.
  """
  @spec rgb_to_rgb565([integer(), ...]) :: <<_::16>>
  def rgb_to_rgb565([r, g, b]) do
    r = gamma_correct(r)
    g = gamma_correct(g)
    b = gamma_correct(b)

    color = (r >>> 3) <<< 11 ||| (g >>> 2) <<< 5 ||| b >>> 3
    <<color::little-16>>
  end

  @doc """
  Convert a raw RGB888 binary to RGB565 little-endian binary.
  Processes 3 bytes at a time, applying gamma correction to each pixel.
  """
  @spec rgb_binary_to_rgb565(binary()) :: binary()
  def rgb_binary_to_rgb565(data) do
    data
    |> rgb565_iodata()
    |> IO.iodata_to_binary()
  end

  defp rgb565_iodata(<<r, g, b, rest::binary>>) do
    [rgb_to_rgb565([r, g, b]) | rgb565_iodata(rest)]
  end

  defp rgb565_iodata(<<>>), do: []

  defp gamma_correct(0), do: 0
  defp gamma_correct(255), do: 255
  defp gamma_correct(value), do: round(:math.pow(value / 255, @gamma_correction) * 255)
end
