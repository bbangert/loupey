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
    field(:max, integer())
  end

  @spec load_image!(String.t()) :: t()
  @spec load_image!(String.t(), non_neg_integer()) :: t()
  def load_image!(path, max \\ 80) do
    img =
      path
      |> Image.open!()
      |> Image.thumbnail!(max)
      |> Image.flatten!()

    %Loupey.Image{
      image: img,
      path: path,
      width: Image.width(img),
      height: Image.height(img),
      max: max
    }
  end

  @doc """
  Creates a new image with the specified background color and embeds the given image centered within it.
  The new image will have the same dimensions as the input image.

  ## Arguments:

  * `img` - The image to embed.
  * `width` - The width of the new image.
  * `height` - The height of the new image.
  * `background_color` - The background color, as any color option accepted by `Image.new!/3`.

  """
  @spec embed_on_background!(t(), pos_integer(), pos_integer(), any()) :: t()
  def embed_on_background!(img, width, height, background_color) do
    composite_img =
      Image.new!(width, height, color: background_color)
      |> Image.compose!(img.image)
      |> Image.flatten!()

    %Loupey.Image{
      img
      | image: composite_img,
        width: width,
        height: height
    }
  end

  @doc """
  Convert an image to a binary in RGB565 format.
  """
  @spec image_to_rgb565_binary!(Vix.Vips.Image.t()) :: binary()
  def image_to_rgb565_binary!(image) do
    image
    |> Vix.Vips.Image.write_to_binary()
    |> elem(1)
    |> Loupey.Color.rgb_to_rgb565()
    |> IO.iodata_to_binary()
  end
end
