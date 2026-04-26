defmodule Loupey.Graphics.RendererTest do
  use ExUnit.Case, async: true

  alias Loupey.Device.{Control, Display}
  alias Loupey.Graphics.Renderer

  defp control(width, height, format \\ :rgb888) do
    %Control{
      id: "test",
      capabilities: MapSet.new([:display]),
      display: %Display{width: width, height: height, pixel_format: format}
    }
  end

  defp solid_image(width, height, color) do
    Image.new!(width, height, color: color)
  end

  describe "apply_overlay" do
    test "fully opaque overlay replaces frame contents" do
      pixels = Renderer.render_frame(%{background: "#FF0000", overlay: "#00FF00"}, control(8, 8))

      # rgb888 — 3 bytes per pixel, all green
      <<r, g, b, _rest::binary>> = pixels
      assert {r, g, b} == {0, 255, 0}
    end

    test "translucent overlay blends with underlying frame" do
      pixels =
        Renderer.render_frame(%{background: "#000000", overlay: "#FFFFFF80"}, control(8, 8))

      <<r, g, b, _rest::binary>> = pixels
      # ~50% alpha white over black should produce a roughly-mid-gray.
      assert r > 100 and r < 180
      assert g > 100 and g < 180
      assert b > 100 and b < 180
    end
  end

  describe "transform: translate" do
    test "shifts the icon by translate_x pixels" do
      icon = solid_image(4, 4, "#FFFFFF")

      base_pixels =
        Renderer.render_frame(
          %{background: "#000000", icon: icon},
          control(16, 16)
        )

      shifted_pixels =
        Renderer.render_frame(
          %{background: "#000000", icon: icon, transform: %{translate_x: 4, translate_y: 0}},
          control(16, 16)
        )

      refute base_pixels == shifted_pixels
    end
  end

  describe "transform: scale" do
    test "scale < 1.0 shrinks the icon footprint" do
      icon = solid_image(8, 8, "#FFFFFF")

      base = Renderer.render_frame(%{background: "#000000", icon: icon}, control(16, 16))

      shrunk =
        Renderer.render_frame(
          %{background: "#000000", icon: icon, transform: %{scale: 0.5}},
          control(16, 16)
        )

      base_white = count_white_pixels_rgb888(base)
      shrunk_white = count_white_pixels_rgb888(shrunk)
      assert shrunk_white < base_white
    end
  end

  describe "icon path resolution" do
    test "string :icon path resolves through IconCache and renders" do
      # Write a temp PNG via Vix so we don't depend on shipped icons.
      tmp_path =
        Path.join(System.tmp_dir!(), "renderer_icon_#{System.unique_integer([:positive])}.png")

      :ok = Image.new!(8, 8, color: "#FF0000") |> Image.write!(tmp_path) |> then(fn _ -> :ok end)
      on_exit(fn -> File.rm(tmp_path) end)

      pixels =
        Renderer.render_frame(%{background: "#000000", icon: tmp_path}, control(16, 16))

      # Frame must render (no crash) and contain at least one red pixel
      # from the icon — distinguishing this from a no-icon black frame.
      assert byte_size(pixels) == 16 * 16 * 3
      assert pixels =~ <<255, 0, 0>>
    end

    test "unresolvable string :icon path renders the frame without the icon" do
      missing =
        Path.join(
          System.tmp_dir!(),
          "definitely-not-here-#{System.unique_integer([:positive])}.png"
        )

      pixels =
        Renderer.render_frame(%{background: "#000000", icon: missing}, control(8, 8))

      # Doesn't crash; frame is just the background (all black).
      assert pixels == :binary.copy(<<0, 0, 0>>, 8 * 8)
    end
  end

  describe "transform: rotate" do
    test "non-90 rotation produces a non-trivially-different frame" do
      # Asymmetric icon: half white, half black, so rotation visibly changes
      # the pixel layout.
      icon =
        Image.compose!(
          Image.new!(8, 8, color: "#000000"),
          Image.new!(8, 4, color: "#FFFFFF"),
          x: 0,
          y: 0
        )
        |> Image.flatten!()

      base = Renderer.render_frame(%{background: "#000000", icon: icon}, control(16, 16))

      rotated =
        Renderer.render_frame(
          %{background: "#000000", icon: icon, transform: %{rotate: 45}},
          control(16, 16)
        )

      refute base == rotated
    end

    test "90-degree rotation flips icon dimensions for non-square sources" do
      # Construct a 12x4 white icon: 90° rotation should change dimensions.
      icon = solid_image(12, 4, "#FFFFFF")

      base = Renderer.render_frame(%{background: "#000000", icon: icon}, control(20, 20))

      rotated =
        Renderer.render_frame(
          %{background: "#000000", icon: icon, transform: %{rotate: 90}},
          control(20, 20)
        )

      refute base == rotated
    end
  end

  defp count_white_pixels_rgb888(pixels) do
    count_white_rgb888(pixels, 0)
  end

  defp count_white_rgb888(<<255, 255, 255, rest::binary>>, count) do
    count_white_rgb888(rest, count + 1)
  end

  defp count_white_rgb888(<<_r, _g, _b, rest::binary>>, count) do
    count_white_rgb888(rest, count)
  end

  defp count_white_rgb888(<<>>, count), do: count
end
