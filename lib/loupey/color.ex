defmodule Loupey.Color do
  @moduledoc """
  Color generation and manipulation utilities.
  """

  import Bitwise

  @doc """
  Create a binary representation of a color that can be used to fill a sliders dimensions, optionally
  filling a percentage of the slider from the bottom up.
  """
  @spec fill_slider_color(String.t(), integer(), integer()) :: nonempty_binary()
  @spec fill_slider_color(String.t(), integer(), integer(), number()) :: nonempty_binary()
  def fill_slider_color(color, width, height, percent \\ 100) do
    filled_height = round(height * (percent / 100))
    empty_height = height - filled_height

    :binary.copy(<<0::16>>, empty_height * width) <> fill_key_color(color, filled_height * width)
  end

  @doc """
  Create a binary in RGB565 of a color for the given quantity of pixels.
  """
  @spec fill_key_color(String.t(), non_neg_integer()) :: nonempty_binary()
  def fill_key_color(color, count) do
    color
    |> parse_color()
    |> rgb_to_rgb565()
    |> :binary.copy(count)
  end

  @doc """
  Generate a random color in hex format, e.g. "#fa29b2".
  """
  @spec random_color() :: String.t()
  def random_color do
    r = :rand.uniform(256) - 1
    g = :rand.uniform(256) - 1
    b = :rand.uniform(256) - 1

    "##{:io_lib.format("~2.16.0B~2.16.0B~2.16.0B", [r, g, b])}"
  end

  @doc """
  Parse a hex color string into a list of R, G, B integers.
  """
  @spec parse_color(String.t()) :: [integer(), ...]
  def parse_color("#" <> color_hex) do
    [
      String.slice(color_hex, 0, 2) |> String.to_integer(16),
      String.slice(color_hex, 2, 2) |> String.to_integer(16),
      String.slice(color_hex, 4, 2) |> String.to_integer(16)
    ]
  end

  @doc """
  Convert an RGB color to RGB565 LE format.
  """
  @spec rgb_to_rgb565([integer(), ...]) :: <<_::16>>
  def rgb_to_rgb565([r, g, b]) do
    r5 = (r >>> 3) <<< 11
    g6 = (g >>> 2) <<< 5
    b5 = b >>> 3

    color = r5 ||| g6 ||| b5
    <<color::little-16>>
  end

  @spec rgb_to_rgb565(binary()) :: binary()
  def rgb_to_rgb565(<<r, g, b, rest::binary>>) do
    [rgb_to_rgb565([r, g, b]), rgb_to_rgb565(rest)]
  end
  def rgb_to_rgb565(<<>>) do
    <<>>
  end
end
