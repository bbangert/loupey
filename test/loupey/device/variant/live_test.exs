defmodule Loupey.Device.Variant.LiveTest do
  use ExUnit.Case, async: true

  alias Loupey.Device.{Layout, Spec}
  alias Loupey.Device.Variant.Live

  describe "is_variant?/1" do
    test "matches the Loupedeck Live vendor/product IDs" do
      assert Live.is_variant?(%{vendor_id: 0x2EC2, product_id: 0x0004})
    end

    test "rejects other devices" do
      refute Live.is_variant?(%{vendor_id: 0x0FD9, product_id: 0x0080})
      refute Live.is_variant?(%{})
    end
  end

  describe "device_spec/0" do
    setup do
      %{spec: Live.device_spec()}
    end

    test "exposes the six physical knobs only (no :knob_ct phantom)", %{spec: spec} do
      knob_ids =
        spec.controls
        |> Enum.filter(&MapSet.member?(&1.capabilities, :rotate))
        |> Enum.map(& &1.id)
        |> Enum.sort()

      assert knob_ids == [:knob_bl, :knob_br, :knob_cl, :knob_cr, :knob_tl, :knob_tr]
    end

    test "does not declare phantom misc buttons", %{spec: spec} do
      ids = Enum.map(spec.controls, & &1.id)

      for phantom <- [:home, :undo, :keyboard, :enter, :save, :fn_l, :fn_r, :a, :b, :c, :d, :e] do
        refute phantom in ids, "phantom control #{inspect(phantom)} still in spec"
      end
    end
  end

  describe "layout/0" do
    setup do
      %{layout: Live.layout(), spec: Live.device_spec()}
    end

    test "returns a %Layout{} with sensible face dimensions", %{layout: layout} do
      assert %Layout{} = layout
      assert layout.face_width > 0
      assert layout.face_height > 0
    end

    test "every control in device_spec/0 has a layout position", %{layout: layout, spec: spec} do
      missing =
        for control <- spec.controls, not Map.has_key?(layout.positions, control.id) do
          control.id
        end

      assert missing == [], "controls missing layout positions: #{inspect(missing)}"
    end

    test "layout positions reference no extra ids beyond device_spec/0", %{
      layout: layout,
      spec: spec
    } do
      spec_ids = MapSet.new(spec.controls, & &1.id)
      extras = layout.positions |> Map.keys() |> Enum.reject(&MapSet.member?(spec_ids, &1))
      assert extras == [], "layout has positions for unknown controls: #{inspect(extras)}"
    end

    test "knobs are round and flank the display", %{layout: layout} do
      for id <- [:knob_tl, :knob_cl, :knob_bl, :knob_tr, :knob_cr, :knob_br] do
        pos = Map.fetch!(layout.positions, id)
        assert pos.shape == :round, "#{inspect(id)} should be round"
      end

      # Left-column knobs share an x; right-column knobs share a different x.
      left_xs = Enum.map([:knob_tl, :knob_cl, :knob_bl], &layout.positions[&1].x)
      right_xs = Enum.map([:knob_tr, :knob_cr, :knob_br], &layout.positions[&1].x)

      assert Enum.uniq(left_xs) |> length() == 1
      assert Enum.uniq(right_xs) |> length() == 1
      assert hd(left_xs) < hd(right_xs)
    end

    test "key positions match the Display.offset grid (shifted by constant face margins)",
         %{layout: layout, spec: spec} do
      # Face coords = display offset + constant (gutter_x, gutter_y) shift
      # shared by every key. Derive the shift from {:key, 0}, verify
      # the remaining 11 keys match.
      pos0 = Map.fetch!(layout.positions, {:key, 0})
      {ox0, oy0} = Spec.find_control(spec, {:key, 0}).display.offset
      gutter_x = pos0.x - ox0
      gutter_y = pos0.y - oy0

      for n <- 0..11 do
        key = Spec.find_control(spec, {:key, n})
        {ox, oy} = key.display.offset
        pos = Map.fetch!(layout.positions, {:key, n})

        assert pos.x == ox + gutter_x
        assert pos.y == oy + gutter_y
        assert pos.width == key.display.width
        assert pos.height == key.display.height
        assert pos.shape == :square
      end

      assert gutter_x > 0, "keys should be offset from the face's left edge"
      assert gutter_y > 0, "keys should be offset from the face's top edge"
    end

    test "strips are tall rectangles", %{layout: layout} do
      for id <- [:left_strip, :right_strip] do
        pos = Map.fetch!(layout.positions, id)
        assert pos.shape == :rect
        assert pos.height > pos.width
      end
    end

    test "the 8 press buttons are round and sit below the display row", %{layout: layout} do
      [first_key | _] = Enum.filter(Map.keys(layout.positions), &match?({:key, _}, &1))
      key_pos = Map.fetch!(layout.positions, first_key)
      display_bottom = key_pos.y + 3 * key_pos.height

      ys =
        for i <- 0..7 do
          pos = Map.fetch!(layout.positions, {:button, i})
          assert pos.shape == :round
          pos.y
        end

      assert Enum.uniq(ys) |> length() == 1
      assert hd(ys) >= display_bottom
    end
  end
end
