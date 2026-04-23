defmodule Loupey.Device.SpecTest do
  use ExUnit.Case, async: true

  alias Loupey.Device.{Control, Display, Spec}

  @spec test_spec() :: Spec.t()
  defp test_spec do
    %Spec{
      type: "Test Device",
      controls: [
        %Control{id: :knob_tl, capabilities: MapSet.new([:rotate, :press])},
        %Control{id: {:button, 0}, capabilities: MapSet.new([:press, :led])},
        %Control{
          id: {:key, 0},
          capabilities: MapSet.new([:touch, :display]),
          display: %Display{
            width: 90,
            height: 90,
            pixel_format: :rgb565,
            offset: {60, 0},
            display_id: <<0x00, 0x4D>>
          }
        },
        %Control{
          id: {:key, 1},
          capabilities: MapSet.new([:touch, :display]),
          display: %Display{
            width: 90,
            height: 90,
            pixel_format: :rgb565,
            offset: {150, 0},
            display_id: <<0x00, 0x4D>>
          }
        },
        %Control{
          id: :left_strip,
          capabilities: MapSet.new([:touch, :display]),
          display: %Display{
            width: 60,
            height: 270,
            pixel_format: :rgb565,
            offset: {0, 0},
            display_id: <<0x00, 0x4D>>
          }
        },
        %Control{id: :example_button, capabilities: MapSet.new([:press])}
      ]
    }
  end

  describe "find_control/2" do
    test "finds a control by id" do
      spec = test_spec()
      assert %Control{id: :knob_tl} = Spec.find_control(spec, :knob_tl)
    end

    test "finds a tuple id control" do
      spec = test_spec()
      assert %Control{id: {:key, 0}} = Spec.find_control(spec, {:key, 0})
    end

    test "returns nil for unknown id" do
      spec = test_spec()
      assert nil == Spec.find_control(spec, :nonexistent)
    end
  end

  describe "controls_with_capability/2" do
    test "finds all controls with :press" do
      spec = test_spec()
      press_controls = Spec.controls_with_capability(spec, :press)
      ids = Enum.map(press_controls, & &1.id)

      assert :knob_tl in ids
      assert {:button, 0} in ids
      assert :example_button in ids
      refute {:key, 0} in ids
    end

    test "finds all controls with :display" do
      spec = test_spec()
      display_controls = Spec.controls_with_capability(spec, :display)
      assert length(display_controls) == 3
    end
  end

  describe "resolve_touch/3" do
    test "resolves touch to the correct key control" do
      spec = test_spec()
      assert %Control{id: {:key, 0}} = Spec.resolve_touch(spec, 80, 45)
    end

    test "resolves touch to second key" do
      spec = test_spec()
      assert %Control{id: {:key, 1}} = Spec.resolve_touch(spec, 160, 45)
    end

    test "resolves touch to left strip" do
      spec = test_spec()
      assert %Control{id: :left_strip} = Spec.resolve_touch(spec, 30, 100)
    end

    test "returns nil for coordinates outside any control" do
      spec = test_spec()
      assert nil == Spec.resolve_touch(spec, 500, 500)
    end
  end
end
