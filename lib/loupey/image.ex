defmodule Loupey.Image do
  import Bitwise

  def fill_slider_color(color, width, height, percent \\ 100) do
    color
    |> parse_color()
    |> rgb_to_rgb565()
    |> fill_slider(width, height, percent)
  end

  def fill_slider(color_bytes, width, height, percent) do
    filled_height = round(height * (percent / 100))
    empty_height = height - filled_height

    empty = :binary.copy(<<0::16>>, empty_height * width)
    filled = :binary.copy(color_bytes, filled_height * width)
    empty <> filled
  end

  def fill_key_color(color, count) do
    color
    |> parse_color()
    |> rgb_to_rgb565()
    |> :binary.copy(count)
  end

  def random_color do
    r = :rand.uniform(256) - 1
    g = :rand.uniform(256) - 1
    b = :rand.uniform(256) - 1

    "##{:io_lib.format("~2.16.0B~2.16.0B~2.16.0B", [r, g, b])}"
  end

  def parse_color("#" <> color_hex) do
    [
      String.slice(color_hex, 0, 2) |> String.to_integer(16),
      String.slice(color_hex, 2, 2) |> String.to_integer(16),
      String.slice(color_hex, 4, 2) |> String.to_integer(16)
    ]
  end

  def load_image(path) do
    path
    |> File.read!()
    |> Image.open!()
    |> Image.resize!(0.5)
    |> Image.flatten!()
    |> convert_to_binary()
  end

  def convert_to_binary(img) do
    Enum.reduce(0..(Image.height(img) - 1), [], fn y, acc ->
      Enum.reduce(0..(Image.width(img) - 1), acc, fn x, acc ->
        pixel = Image.get_pixel!(img, x, y) |> rgb_to_rgb565()
        [acc, pixel]
      end)
    end)
    |> IO.iodata_to_binary()
  end

  def rgb_to_rgb565([r, g, b]) do
    r5 = (r >>> 3) <<< 11
    g6 = (g >>> 2) <<< 5
    b5 = b >>> 3

    color = r5 ||| g6 ||| b5
    <<color::little-16>>
  end
end
