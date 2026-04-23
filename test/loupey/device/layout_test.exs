defmodule Loupey.Device.LayoutTest do
  use ExUnit.Case, async: true

  alias Loupey.Device.Layout

  describe "struct" do
    test "builds with required keys" do
      layout = %Layout{
        face_width: 600,
        face_height: 400,
        positions: %{
          {:key, 0} => %{x: 60, y: 0, width: 90, height: 90, shape: :square},
          :knob_tl => %{x: 15, y: 30, width: 40, height: 40, shape: :round}
        }
      }

      assert layout.face_width == 600
      assert layout.face_height == 400
      assert layout.positions[{:key, 0}].shape == :square
      assert layout.positions[:knob_tl].shape == :round
    end

    test "enforces required keys" do
      assert_raise ArgumentError, fn ->
        struct!(Layout, face_width: 10, face_height: 10)
      end
    end
  end
end
