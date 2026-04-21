defmodule Loupey.Device.Variant.ClassicTest do
  use ExUnit.Case, async: true

  alias Loupey.Device.{Control, Spec}
  alias Loupey.Device.Variant.Classic

  describe "is_variant?/1" do
    test "matches each of the four documented Classic-family PIDs" do
      for pid <- [0x0080, 0x00A5, 0x006D, 0x00B9] do
        assert Classic.is_variant?(%{vendor_id: 0x0FD9, product_id: pid}),
               "expected PID 0x#{Integer.to_string(pid, 16)} to match"
      end
    end

    test "rejects MK.1 (0x0060) — different command set, explicitly out of scope" do
      refute Classic.is_variant?(%{vendor_id: 0x0FD9, product_id: 0x0060})
    end

    test "rejects other Elgato devices" do
      refute Classic.is_variant?(%{vendor_id: 0x0FD9, product_id: 0x0001})
    end

    test "rejects non-Elgato vendors even with matching PID" do
      refute Classic.is_variant?(%{vendor_id: 0x2EC2, product_id: 0x00B9})
    end

    test "returns false for non-matching device_info shapes" do
      refute Classic.is_variant?(%{})
      refute Classic.is_variant?(%{vendor_id: 0x0FD9})
      refute Classic.is_variant?(nil)
      refute Classic.is_variant?("not a map")
    end
  end

  describe "device_spec/0" do
    setup do
      %{spec: Classic.device_spec()}
    end

    test "reports a family-wide device type label", %{spec: spec} do
      # Family label, not a specific model — the variant covers four PIDs
      # (MK.2, Scissor Keys, 2019, 15-Key Module) that share one command set.
      assert spec.type == "Stream Deck (Classic)"
    end

    test "exposes exactly 15 controls (5×3 grid)", %{spec: spec} do
      assert length(spec.controls) == 15
    end

    test "every control is a key with :press and :display capabilities", %{spec: spec} do
      for %Control{} = control <- spec.controls do
        assert match?({:key, _}, control.id)
        assert MapSet.member?(control.capabilities, :press)
        assert MapSet.member?(control.capabilities, :display)
      end
    end

    test "key IDs are 0..14 in row-major order", %{spec: spec} do
      ids = Enum.map(spec.controls, & &1.id)
      assert ids == for(n <- 0..14, do: {:key, n})
    end

    test "each display is 72×72, JPEG, with per-key offset and no shared display_id",
         %{spec: spec} do
      for control <- spec.controls do
        {:key, n} = control.id
        col = rem(n, 5)
        row = div(n, 5)

        assert control.display.width == 72
        assert control.display.height == 72
        # :jpeg_flipped — the Stream Deck mounts its LCD upside-down, so
        # images are rotated 180° before JPEG encoding.
        assert control.display.pixel_format == :jpeg_flipped
        assert control.display.offset == {col * 72, row * 72}
        # Stream Deck writes each key atomically — no shared framebuffer, so
        # display_id stays nil and the driver skips the (optional) refresh step.
        assert is_nil(control.display.display_id)
      end
    end

    test "Spec.find_control/2 can look up every key", %{spec: spec} do
      for n <- 0..14 do
        assert %Control{id: {:key, ^n}} = Spec.find_control(spec, {:key, n})
      end
    end
  end

  describe "vendor_id/0 and product_ids/0" do
    test "exposes Elgato's vendor ID" do
      assert Classic.vendor_id() == 0x0FD9
    end

    test "exposes the four Classic-family PIDs" do
      # Order isn't part of the contract — @product_ids is only consumed by
      # `pid in @product_ids` in is_variant?/1, so assert set equality.
      assert MapSet.new(Classic.product_ids()) ==
               MapSet.new([0x0080, 0x00A5, 0x006D, 0x00B9])
    end
  end
end
