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
    field(:image, Vix.Vips.Image.t())
    field(:path, String.t())
    field(:width, integer())
    field(:height, integer())
    field(:data, binary())
  end

  @spec load_image!(String.t()) :: Loupey.Image.t()
  @spec load_image!(String.t(), non_neg_integer()) :: Loupey.Image.t()
  def load_image!(path, max \\ 80) do
    img =
      path
      |> Image.thumbnail!(max)
      |> Image.flatten!()

    %Loupey.Image{
      image: img,
      path: path,
      width: Image.width(img),
      height: Image.height(img),
      data: image_to_rgb565_binary!(img)
    }
  end

  @doc """
  Creates a new image with the specified background color and embeds the given image centered within it.
  The new image will have the same dimensions as the input image.
  """
  @spec embed_on_background!(Loupey.Image.t(), integer(), integer(), String.t()) :: Loupey.Image.t()
  def embed_on_background!(img, width, height, background_hex) do
    bg_img = Image.new!(width, height, color: background_hex)

    composite_img =
      bg_img
      |> Image.compose!(img.image)
      |> Image.flatten!()

    %Loupey.Image{
      image: composite_img,
      path: img.path,
      width: width,
      height: height,
      data: image_to_rgb565_binary!(composite_img)
    }
  end

  defp image_to_rgb565_binary!(image) do
    image
    |> Vix.Vips.Image.write_to_binary()
    |> elem(1)
    |> Loupey.Color.rgb_to_rgb565()
    |> IO.iodata_to_binary()
  end
end
