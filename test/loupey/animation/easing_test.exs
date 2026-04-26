defmodule Loupey.Animation.EasingTest do
  use ExUnit.Case, async: true

  alias Loupey.Animation.Easing

  describe "resolve/1" do
    test "linear is identity" do
      f = Easing.resolve(:linear)
      assert f.(0.0) == 0.0
      assert f.(0.25) == 0.25
      assert f.(0.5) == 0.5
      assert f.(1.0) == 1.0
    end

    test "named easings dispatch to bezier solver" do
      for name <- [:ease, :ease_in, :ease_out, :ease_in_out] do
        f = Easing.resolve(name)
        assert is_function(f, 1)
        assert f.(0.0) == 0.0
        assert f.(1.0) == 1.0
        mid = f.(0.5)
        assert mid > 0.0 and mid < 1.0
      end
    end

    test "ease_in is a slow start (mid below 0.5), ease_out is a slow end (mid above 0.5)" do
      assert Easing.resolve(:ease_in).(0.5) < 0.5
      assert Easing.resolve(:ease_out).(0.5) > 0.5
    end

    test "step_start is 1.0 for any t > 0, 0.0 at t = 0" do
      f = Easing.resolve(:step_start)
      assert f.(0.0) == 0.0
      assert f.(0.001) == 1.0
      assert f.(0.5) == 1.0
      assert f.(1.0) == 1.0
    end

    test "step_end is 0.0 until t == 1.0, then 1.0" do
      f = Easing.resolve(:step_end)
      assert f.(0.0) == 0.0
      assert f.(0.5) == 0.0
      assert f.(0.999) == 0.0
      assert f.(1.0) == 1.0
    end

    test "explicit cubic_bezier tuple" do
      f = Easing.resolve({:cubic_bezier, 0.42, 0.0, 0.58, 1.0})
      assert_in_delta f.(0.5), 0.5, 0.01
    end

    test "unknown easing raises ArgumentError" do
      assert_raise ArgumentError, ~r/unknown easing/, fn ->
        Easing.resolve(:wibble)
      end
    end
  end
end
