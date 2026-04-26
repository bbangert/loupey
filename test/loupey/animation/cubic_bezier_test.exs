defmodule Loupey.Animation.CubicBezierTest do
  use ExUnit.Case, async: true

  alias Loupey.Animation.CubicBezier

  describe "boundary cases" do
    test "t == 0 returns 0" do
      assert CubicBezier.call(0.42, 0.0, 0.58, 1.0, 0.0) == 0.0
    end

    test "t == 1 returns 1" do
      assert CubicBezier.call(0.42, 0.0, 0.58, 1.0, 1.0) == 1.0
    end

    test "t < 0 clamps to 0" do
      assert CubicBezier.call(0.25, 0.1, 0.25, 1.0, -0.5) == 0.0
    end

    test "t > 1 clamps to 1" do
      assert CubicBezier.call(0.25, 0.1, 0.25, 1.0, 1.5) == 1.0
    end
  end

  describe "named curve reference values (MDN spot checks)" do
    test "ease_in_out at midpoint is approximately 0.5" do
      result = CubicBezier.call(0.42, 0.0, 0.58, 1.0, 0.5)
      assert_in_delta result, 0.5, 0.01
    end

    test "ease_in at 0.5 is below 0.5 (slow start)" do
      result = CubicBezier.call(0.42, 0.0, 1.0, 1.0, 0.5)
      assert result < 0.5
    end

    test "ease_out at 0.5 is above 0.5 (slow end)" do
      result = CubicBezier.call(0.0, 0.0, 0.58, 1.0, 0.5)
      assert result > 0.5
    end
  end

  describe "monotonicity" do
    @curves [
      {0.25, 0.1, 0.25, 1.0},
      {0.42, 0.0, 1.0, 1.0},
      {0.0, 0.0, 0.58, 1.0},
      {0.42, 0.0, 0.58, 1.0}
    ]

    test "named curves are monotonic on [0, 1]" do
      ts = Enum.map(0..100, &(&1 / 100.0))

      for {x1, y1, x2, y2} <- @curves do
        results = Enum.map(ts, &CubicBezier.call(x1, y1, x2, y2, &1))

        Enum.zip(results, tl(results))
        |> Enum.each(fn {a, b} ->
          assert a <= b + 1.0e-6, "non-monotonic: #{a} > #{b} for {#{x1},#{y1},#{x2},#{y2}}"
        end)
      end
    end
  end
end
