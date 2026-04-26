defmodule Loupey.Animation.TweenTest do
  use ExUnit.Case, async: true

  alias Loupey.Animation.Tween

  describe "iteration_and_progress/3" do
    test "before-start returns iter 0, progress 0" do
      assert Tween.iteration_and_progress(-100, 1000, 1) == {0, 0.0}
    end

    test "first iteration midpoint" do
      assert Tween.iteration_and_progress(500, 1000, 3) == {0, 0.5}
    end

    test "third iteration midpoint" do
      assert Tween.iteration_and_progress(2500, 1000, 3) == {2, 0.5}
    end

    test "exact iteration boundary" do
      assert Tween.iteration_and_progress(1000, 1000, 3) == {1, 0.0}
    end

    test "completed finite iterations" do
      assert Tween.iteration_and_progress(3000, 1000, 3) == :done
      assert Tween.iteration_and_progress(5000, 1000, 3) == :done
    end

    test "infinite iterations never returns :done" do
      assert Tween.iteration_and_progress(999_999_000, 1000, :infinite) == {999_999, 0.0}
    end
  end

  describe "apply_direction/3" do
    test ":normal returns progress unchanged" do
      assert Tween.apply_direction(0.3, 0, :normal) == 0.3
      assert Tween.apply_direction(0.3, 5, :normal) == 0.3
    end

    test ":reverse flips progress" do
      assert Tween.apply_direction(0.3, 0, :reverse) == 0.7
    end

    test ":alternate bounces on odd iterations" do
      assert Tween.apply_direction(0.3, 0, :alternate) == 0.3
      assert Tween.apply_direction(0.3, 1, :alternate) == 0.7
      assert Tween.apply_direction(0.3, 2, :alternate) == 0.3
    end

    test ":alternate_reverse bounces opposite" do
      assert Tween.apply_direction(0.3, 0, :alternate_reverse) == 0.7
      assert Tween.apply_direction(0.3, 1, :alternate_reverse) == 0.3
    end
  end

  describe "lerp_rgb/3" do
    test "endpoints are exact" do
      assert Tween.lerp_rgb({0, 0, 0}, {255, 255, 255}, 0.0) == {0, 0, 0}
      assert Tween.lerp_rgb({0, 0, 0}, {255, 255, 255}, 1.0) == {255, 255, 255}
    end

    test "midpoint" do
      assert Tween.lerp_rgb({0, 0, 0}, {200, 100, 50}, 0.5) == {100, 50, 25}
    end

    test "clamps t" do
      assert Tween.lerp_rgb({10, 20, 30}, {200, 100, 50}, -1.0) == {10, 20, 30}
      assert Tween.lerp_rgb({10, 20, 30}, {200, 100, 50}, 2.0) == {200, 100, 50}
    end
  end

  describe "lerp_number/3" do
    test "endpoints" do
      assert Tween.lerp_number(0, 100, 0.0) == 0.0
      assert Tween.lerp_number(0, 100, 1.0) == 100.0
    end

    test "midpoint" do
      assert Tween.lerp_number(0, 100, 0.5) == 50.0
    end

    test "negative ranges" do
      assert Tween.lerp_number(-10, 10, 0.5) == 0.0
    end
  end

  describe "parse_color/1" do
    test "uppercase hex" do
      assert Tween.parse_color("#FF8000") == {255, 128, 0}
    end

    test "lowercase hex" do
      assert Tween.parse_color("#0a14ff") == {10, 20, 255}
    end
  end

  describe "lerp_keyframe/2" do
    test "single stop returns its map" do
      stops = [{0, %{amount: 1.0}}]
      assert Tween.lerp_keyframe(stops, 0.5) == %{amount: 1.0}
    end

    test "two stops at endpoints" do
      stops = [{0, %{amount: 0.0}}, {100, %{amount: 1.0}}]
      assert Tween.lerp_keyframe(stops, 0.5) == %{amount: 0.5}
    end

    test "finds correct surrounding stops in 3-stop sequence" do
      stops = [
        {0, %{amount: 0.0}},
        {50, %{amount: 1.0}},
        {100, %{amount: 0.0}}
      ]

      assert Tween.lerp_keyframe(stops, 0.25) == %{amount: 0.5}
      assert Tween.lerp_keyframe(stops, 0.75) == %{amount: 0.5}
    end

    test "lerps RGB-shaped values" do
      stops = [
        {0, %{color: "#000000"}},
        {100, %{color: "#FFFFFF"}}
      ]

      result = Tween.lerp_keyframe(stops, 0.5)
      assert {r, g, b} = result.color
      assert_in_delta r, 128, 1
      assert_in_delta g, 128, 1
      assert_in_delta b, 128, 1
    end

    test "lerps RGBA-shaped values back to a hex string with alpha" do
      stops = [
        {0, %{overlay: "#FFD70000"}},
        {100, %{overlay: "#FFD70080"}}
      ]

      result = Tween.lerp_keyframe(stops, 0.5)
      assert is_binary(result.overlay)
      assert String.starts_with?(result.overlay, "#FFD700")
      # 0x00 → 0x80 midpoint is 0x40 (64); allow ±1 for rounding.
      <<"#", _bg::binary-size(6), alpha_hex::binary-size(2)>> = result.overlay
      alpha = String.to_integer(alpha_hex, 16)
      assert_in_delta alpha, 64, 1
    end

    test "lerps mixed 6-hex and 8-hex by treating 6-hex as alpha=255" do
      stops = [
        {0, %{overlay: "#FFFFFF"}},
        {100, %{overlay: "#FFFFFF00"}}
      ]

      result = Tween.lerp_keyframe(stops, 0.5)
      assert is_binary(result.overlay)
      <<"#", _bg::binary-size(6), alpha_hex::binary-size(2)>> = result.overlay
      assert_in_delta String.to_integer(alpha_hex, 16), 128, 1
    end

    test "non-numeric, non-color values step" do
      stops = [{0, %{label: "off"}}, {100, %{label: "on"}}]
      assert Tween.lerp_keyframe(stops, 0.5) == %{label: "off"}
      assert Tween.lerp_keyframe(stops, 1.0) == %{label: "on"}
    end

    test "nested maps lerp recursively" do
      stops = [
        {0, %{fill: %{amount: 30, color: "#000000"}}},
        {100, %{fill: %{amount: 100, color: "#FFFFFF"}}}
      ]

      result = Tween.lerp_keyframe(stops, 0.5)
      assert_in_delta result.fill.amount, 65, 0.5
      assert {r, g, b} = result.fill.color
      assert_in_delta r, 128, 1
      assert_in_delta g, 128, 1
      assert_in_delta b, 128, 1
    end

    test "before first stop returns first stop's value" do
      stops = [{20, %{amount: 0.5}}, {100, %{amount: 1.0}}]
      assert Tween.lerp_keyframe(stops, 0.1) == %{amount: 0.5}
    end

    test "unsorted input is sorted" do
      stops = [{100, %{amount: 1.0}}, {0, %{amount: 0.0}}]
      assert Tween.lerp_keyframe(stops, 0.5) == %{amount: 0.5}
    end
  end
end
