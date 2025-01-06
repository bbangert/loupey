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
    field(:path, String.t())
    field(:width, integer())
    field(:height, integer())
    field(:max, integer())
  end

  @doc """
  Creates a new image with the specified path and maximum size.

  ### Arguments:

  * `path` - The path to the image file.
  * `max` - The maximum size the image should be resized to (default: 80).

  """
  @spec new!(String.t()) :: t()
  @spec new!(String.t(), non_neg_integer()) :: t()
  def new!(path, max \\ 80) do
    img = path |> Image.thumbnail!(max)

    %__MODULE__{
      path: path,
      width: Image.width(img),
      height: Image.height(img),
      max: max
    }
  end

  @doc """
  Creates a new image with the specified background color and embeds the given image centered within it.
  The new image will have the same dimensions as the input image.

  ### Arguments:

  * `img` - The image to embed.
  * `width` - The width of the new image.
  * `height` - The height of the new image.
  * `background_color` - The background color, as any color option accepted by `Image.new!/3`.

  """
  @spec embed_on_background!(t(), pos_integer(), pos_integer(), any()) :: Vix.Vips.Image.t()
  def embed_on_background!(img, width, height, background_color) do
    Image.new!(width, height, color: background_color)
    |> Image.compose!(to_vips_image!(img))
    |> Image.flatten!()
  end

  @doc """
  Convert an image to a Vix.Vips.Image.

  ### Arguments:

  * `img` - The image to convert to a `Vix.Vips.Image`.

  """
  @spec to_vips_image!(t()) :: Vix.Vips.Image.t()
  def to_vips_image!(img) do
    img.path
    |> Image.thumbnail!(img.max)
    |> Image.flatten!()
  end

  @doc """
  Convert an image to a binary in RGB565 format.

  ### Arguments:

  * `image` - The image to convert to a binary in RGB565 format.

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
