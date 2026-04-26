defmodule Loupey.Animation.KeyframesTest do
  use ExUnit.Case, async: true

  alias Loupey.Animation.Keyframes

  describe "parse/1 — required fields" do
    test "missing :duration_ms raises" do
      assert_raise ArgumentError, ~r/missing required key :duration_ms/, fn ->
        Keyframes.parse(%{keyframes: %{0 => %{}}})
      end
    end

    test "missing :keyframes raises" do
      assert_raise ArgumentError, ~r/non-empty :keyframes map/, fn ->
        Keyframes.parse(%{duration_ms: 500})
      end
    end

    test "empty :keyframes map raises" do
      assert_raise ArgumentError, ~r/non-empty :keyframes map/, fn ->
        Keyframes.parse(%{duration_ms: 500, keyframes: %{}})
      end
    end

    test "non-positive duration raises" do
      assert_raise ArgumentError, ~r/positive integer/, fn ->
        Keyframes.parse(%{duration_ms: 0, keyframes: %{0 => %{}}})
      end
    end
  end

  describe "parse/1 — defaults" do
    test "defaults to linear/normal/iterations=1 when unspecified" do
      kf =
        Keyframes.parse(%{
          duration_ms: 500,
          keyframes: %{0 => %{amount: 0.0}, 100 => %{amount: 1.0}}
        })

      assert kf.iterations == 1
      assert kf.direction == :normal
      assert is_function(kf.easing, 1)
      # linear: identity
      assert kf.easing.(0.5) == 0.5
    end
  end

  describe "parse/1 — keyframe stops" do
    test "sorts stops by percentage" do
      kf =
        Keyframes.parse(%{
          duration_ms: 1000,
          keyframes: %{
            100 => %{amount: 1.0},
            0 => %{amount: 0.0},
            50 => %{amount: 0.5}
          }
        })

      assert Enum.map(kf.stops, &elem(&1, 0)) == [0, 50, 100]
    end

    test "accepts string stop keys" do
      kf =
        Keyframes.parse(%{
          duration_ms: 1000,
          keyframes: %{"0" => %{amount: 0.0}, "100" => %{amount: 1.0}}
        })

      assert Enum.map(kf.stops, &elem(&1, 0)) == [0, 100]
    end

    test "rejects out-of-range stop percentages" do
      assert_raise ArgumentError, ~r/0..100/, fn ->
        Keyframes.parse(%{
          duration_ms: 1000,
          keyframes: %{150 => %{amount: 1.0}}
        })
      end
    end
  end

  describe "parse/1 — easing resolution" do
    test "named easing is resolved into a function" do
      kf =
        Keyframes.parse(%{
          duration_ms: 1000,
          easing: :ease_in_out,
          keyframes: %{0 => %{}, 100 => %{}}
        })

      assert is_function(kf.easing, 1)
      assert_in_delta kf.easing.(0.5), 0.5, 0.01
    end

    test "unknown easing raises at parse time" do
      assert_raise ArgumentError, ~r/unknown easing/, fn ->
        Keyframes.parse(%{
          duration_ms: 1000,
          easing: :wibble,
          keyframes: %{0 => %{}, 100 => %{}}
        })
      end
    end
  end

  describe "parse/1 — direction & iterations" do
    test "valid directions accepted" do
      for dir <- [:normal, :reverse, :alternate, :alternate_reverse] do
        kf =
          Keyframes.parse(%{
            duration_ms: 1000,
            direction: dir,
            keyframes: %{0 => %{}, 100 => %{}}
          })

        assert kf.direction == dir
      end
    end

    test "infinite iterations" do
      kf =
        Keyframes.parse(%{
          duration_ms: 1000,
          iterations: :infinite,
          keyframes: %{0 => %{}, 100 => %{}}
        })

      assert kf.iterations == :infinite
    end

    test "invalid direction raises" do
      assert_raise ArgumentError, ~r/direction must be/, fn ->
        Keyframes.parse(%{
          duration_ms: 1000,
          direction: :spinny,
          keyframes: %{0 => %{}, 100 => %{}}
        })
      end
    end
  end

  describe "parse/1 — effect dispatch" do
    test "effect map is routed to Effects.from_map" do
      kf = Keyframes.parse(%{effect: :pulse, duration_ms: 500})
      assert kf.duration_ms == 500
    end

    test "unknown effect name raises" do
      assert_raise ArgumentError, ~r/unknown effect/, fn ->
        Keyframes.parse(%{effect: :no_such_effect, duration_ms: 100})
      end
    end
  end
end
