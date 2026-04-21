defmodule Loupey.Graphics.FormatTest do
  use ExUnit.Case, async: true

  alias Loupey.Graphics.Format
  alias Vix.Vips.Operation

  describe "to_device_format/2 dispatch" do
    test "routes :jpeg_flipped through the rotated encoder" do
      image = Image.new!(4, 2, color: "#FF0000")
      direct = Format.to_jpeg_flipped(image)
      via_dispatch = Format.to_device_format(image, :jpeg_flipped)
      assert direct == via_dispatch
    end

    test "routes :jpeg through the unrotated encoder" do
      image = Image.new!(4, 2, color: "#FF0000")
      direct = Format.to_jpeg(image)
      via_dispatch = Format.to_device_format(image, :jpeg)
      assert direct == via_dispatch
    end
  end

  describe "to_jpeg_flipped/2" do
    test "produces a valid JPEG (SOI / EOI markers)" do
      image = Image.new!(8, 8, color: "#C86432")
      bytes = Format.to_jpeg_flipped(image)

      assert byte_size(bytes) > 4
      assert binary_part(bytes, 0, 2) == <<0xFF, 0xD8>>
      assert binary_part(bytes, byte_size(bytes) - 2, 2) == <<0xFF, 0xD9>>
    end

    test "produces byte-identical output to to_jpeg(rot(180)(image))" do
      # The rotation should happen BEFORE JPEG encoding — encoding a rotated
      # image directly should produce the same bytes as to_jpeg_flipped.
      image = Image.new!(16, 8, color: "#336699")
      rotated = Operation.rot!(image, :VIPS_ANGLE_D180)

      assert Format.to_jpeg_flipped(image) == Format.to_jpeg(rotated, 80)
    end

    test "differs from to_jpeg output for an asymmetric image (rotation did something)" do
      # A solid-color image would be rotation-invariant at the pixel level,
      # so use something asymmetric. A 4×2 image with a red pixel-strip on
      # the left is not rotationally symmetric.
      image = Image.new!(8, 8, color: "#000000")
      # Stamp a solid white 4×8 block on the left half to make it asymmetric
      white = Image.new!(4, 8, color: "#FFFFFF")
      composed = Operation.composite2!(image, white, :VIPS_BLEND_MODE_OVER, x: 0, y: 0)

      plain = Format.to_jpeg(composed)
      flipped = Format.to_jpeg_flipped(composed)

      refute plain == flipped
    end
  end

  describe "to_jpeg/2 (regression — unchanged behaviour)" do
    test "produces a JPEG" do
      image = Image.new!(4, 4, color: "#00FF00")
      bytes = Format.to_jpeg(image)
      assert binary_part(bytes, 0, 2) == <<0xFF, 0xD8>>
    end
  end
end
