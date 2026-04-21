defmodule Loupey.Graphics.Format do
  @moduledoc """
  Pixel format conversion from Vix images to device-native binary formats.

  Each device control declares its pixel format (`:rgb565`, `:rgb888`,
  `:jpeg`, `:jpeg_flipped`). This module converts a `Vix.Vips.Image` into
  the appropriate binary format.

  `:jpeg_flipped` rotates 180° before JPEG encoding — used by the Elgato
  Stream Deck family whose keys are physically oriented upside-down
  relative to the user.
  """

  alias Loupey.Graphics.Color
  alias Vix.Vips

  @doc """
  Convert a Vix image to device-native binary in the given pixel format.
  """
  @spec to_device_format(Vips.Image.t(), Loupey.Device.Display.pixel_format()) :: binary()
  def to_device_format(image, :rgb565), do: to_rgb565(image)
  def to_device_format(image, :jpeg), do: to_jpeg(image)
  def to_device_format(image, :jpeg_flipped), do: to_jpeg_flipped(image)
  def to_device_format(image, :rgb888), do: to_rgb888(image)

  @doc """
  Convert a Vix image to RGB565 little-endian binary.
  """
  @spec to_rgb565(Vips.Image.t()) :: binary()
  def to_rgb565(image) do
    image
    |> Image.flatten!()
    |> Vips.Image.write_to_binary()
    |> elem(1)
    |> Color.rgb_binary_to_rgb565()
  end

  @doc """
  Convert a Vix image to JPEG binary.
  """
  @spec to_jpeg(Vips.Image.t(), pos_integer()) :: binary()
  def to_jpeg(image, quality \\ 90) do
    {:ok, binary} = Vips.Operation.jpegsave_buffer(image, Q: quality)
    binary
  end

  @doc """
  Convert a Vix image to JPEG after rotating 180°. The Elgato Stream Deck
  family mounts its LCDs upside-down relative to the user, so images written
  to the device have to be flipped before encoding.
  """
  @spec to_jpeg_flipped(Vips.Image.t(), pos_integer()) :: binary()
  def to_jpeg_flipped(image, quality \\ 80) do
    image
    |> Vips.Operation.rot!(:VIPS_ANGLE_D180)
    |> to_jpeg(quality)
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
