defmodule Loupey.Animation.EffectsTest do
  use ExUnit.Case, async: true

  alias Loupey.Animation.{Effects, Keyframes}

  describe "from_map/2 dispatch" do
    test "routes :pulse" do
      assert %Keyframes{} = Effects.from_map(:pulse, %{})
    end

    test "routes string effect names" do
      assert %Keyframes{} = Effects.from_map("flash", %{})
    end

    test "unknown effect raises" do
      assert_raise ArgumentError, ~r/unknown effect/, fn ->
        Effects.from_map(:no_such_effect, %{})
      end
    end

    test "unknown string effect raises" do
      assert_raise ArgumentError, ~r/unknown effect/, fn ->
        Effects.from_map("not_an_effect_anywhere_else_xyzzy", %{})
      end
    end
  end

  describe "pulse/1" do
    test "produces an alternating overlay animation" do
      kf = Effects.pulse(%{})
      assert kf.iterations == :infinite
      assert kf.direction == :alternate
      stops = Map.new(kf.stops, fn {pct, m} -> {pct, m} end)
      assert match?("#" <> _, stops[0].overlay)
      assert match?("#" <> _, stops[100].overlay)
    end

    test "respects color and duration overrides" do
      kf = Effects.pulse(%{color: "#FFD700", duration_ms: 800, intensity: 100})
      assert kf.duration_ms == 800
      stops = Map.new(kf.stops, fn {pct, m} -> {pct, m} end)
      assert String.starts_with?(stops[100].overlay, "#FFD700")
    end
  end

  describe "flash/1" do
    test "single-shot fade-out" do
      kf = Effects.flash(%{})
      assert kf.iterations == 1
      assert kf.direction == :normal
    end
  end

  describe "shake/1" do
    test "produces a five-stop translate_x oscillation on the icon" do
      kf = Effects.shake(%{amplitude: 6})
      assert kf.target == :icon
      pcts = Enum.map(kf.stops, &elem(&1, 0))
      assert pcts == [0, 25, 50, 75, 100]

      stops = Map.new(kf.stops, fn {pct, m} -> {pct, m} end)
      assert stops[25].transform.translate_x == -6
      assert stops[50].transform.translate_x == 6
    end
  end

  describe "wiggle/1" do
    test "rotational oscillation" do
      kf = Effects.wiggle(%{angle: 12})
      stops = Map.new(kf.stops, fn {pct, m} -> {pct, m} end)
      assert stops[0].transform.rotate == 0
      assert stops[25].transform.rotate == -12
      assert stops[75].transform.rotate == 12
    end
  end

  describe "squish/1" do
    test "scales icon down and back up" do
      kf = Effects.squish(%{min_scale: 0.85})
      stops = Map.new(kf.stops, fn {pct, m} -> {pct, m} end)
      assert stops[0].transform.scale == 1.0
      assert stops[50].transform.scale == 0.85
      assert stops[100].transform.scale == 1.0
    end
  end

  describe "ripple/1" do
    test "produces an overlay fade-out keyframe" do
      kf = Effects.ripple(%{color: "#FFFFFF", intensity: 128})
      stops = Map.new(kf.stops, fn {pct, m} -> {pct, m} end)
      assert String.starts_with?(stops[0].overlay, "#FFFFFF")
      assert String.starts_with?(stops[100].overlay, "#FFFFFF")
      # Final alpha is 00 (transparent).
      assert String.ends_with?(stops[100].overlay, "00")
    end
  end

  describe "Keyframes.parse/1 effect dispatch (Phase 4 ↔ Phase 7 wiring)" do
    test "effect map parses via Effects.from_map" do
      kf = Keyframes.parse(%{effect: :pulse, duration_ms: 600})
      assert kf.duration_ms == 600
    end
  end
end
