defmodule Loupey.Graphics.Format do
  @moduledoc """
  Pixel format conversion from Vix images to device-native binary formats.

  Each device control declares its pixel format (`:rgb565`, `:jpeg`, `:rgb888`).
  This module converts a `Vix.Vips.Image` into the appropriate binary format.
  """

  alias Vix.Vips

  @doc """
  Convert a Vix image to device-native binary in the given pixel format.
  """
  @spec to_device_format(Vips.Image.t(), Loupey.Device.Display.pixel_format()) :: binary()
  def to_device_format(image, :rgb565), do: to_rgb565(image)
  def to_device_format(image, :jpeg), do: to_jpeg(image)
  def to_device_format(image, :rgb888), do: to_rgb888(image)

  @doc """
  Convert a Vix image to RGB565 little-endian binary.
  Generalizes the existing `Loupey.Graphics.Image.image_to_rgb565_binary!/1`.
  """
  @spec to_rgb565(Vips.Image.t()) :: binary()
  def to_rgb565(image) do
    image
    |> Image.flatten!()
    |> Vips.Image.write_to_binary()
    |> elem(1)
    |> Loupey.Color.rgb_to_rgb565()
    |> IO.iodata_to_binary()
  end

  @doc """
  Convert a Vix image to JPEG binary (for Stream Deck devices).
  """
  @spec to_jpeg(Vips.Image.t(), pos_integer()) :: binary()
  def to_jpeg(image, quality \\ 90) do
    {:ok, binary} = Vips.Operation.jpegsave_buffer(image, Q: quality)
    binary
  end

  @doc """
  Convert a Vix image to raw RGB888 binary.
  """
  @spec to_rgb888(Vips.Image.t()) :: binary()
  def to_rgb888(image) do
    image
    |> Image.flatten!()
    |> Vips.Image.write_to_binary()
    |> elem(1)
  end
end
