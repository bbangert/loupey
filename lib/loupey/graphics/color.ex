defmodule Loupey.Graphics.Color do
  @moduledoc """
  Color parsing and RGB565 conversion for device rendering.
  """

  import Bitwise

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
  """
  @spec rgb_to_rgb565([integer(), ...]) :: <<_::16>>
  def rgb_to_rgb565([r, g, b]) do
    color = (r >>> 3) <<< 11 ||| (g >>> 2) <<< 5 ||| b >>> 3
    <<color::little-16>>
  end

  @doc """
  Convert a raw RGB888 binary to RGB565 little-endian binary.
  Processes 3 bytes at a time.
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
end
