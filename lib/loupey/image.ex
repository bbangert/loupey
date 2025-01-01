defmodule Loupey.Image do
  @moduledoc """
  Image loading, parsing, resizing and conversion utilities.
  """

  use TypedStruct

  typedstruct enforce: true do
    @typedoc """
    A struct representing an image loaded from a file and its binary thumbnail
    data formatted for the Loupedeck device.
    """
    field(:img, Vix.Vips.Image.t())
    field(:width, integer())
    field(:height, integer())
    field(:data, binary())
  end

  @spec load_image(String.t()) :: Loupey.Image.t()
  @spec load_image(String.t(), non_neg_integer()) :: Loupey.Image.t()
  def load_image(path, max \\ 80) do
    img =
      path
      |> File.read!()
      |> Image.open!()

    data =
      img
      |> Image.thumbnail!(max)
      |> Image.flatten!()
      |> convert_to_binary()

    %Loupey.Image{width: Image.width(img), height: Image.height(img), img: img, data: data}
  end

  defp convert_to_binary(img) do
    Enum.reduce(0..(Image.height(img) - 1), [], fn y, acc ->
      Enum.reduce(0..(Image.width(img) - 1), acc, fn x, acc ->
        pixel = Image.get_pixel!(img, x, y) |> Loupey.Color.rgb_to_rgb565()
        [acc, pixel]
      end)
    end)
    |> IO.iodata_to_binary()
  end
end
