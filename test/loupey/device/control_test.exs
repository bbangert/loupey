defmodule Loupey.Device.ControlTest do
  use ExUnit.Case, async: true

  alias Loupey.Device.Control

  describe "has_capability?/2" do
    test "returns true when capability is present" do
      control = %Control{id: :knob, capabilities: MapSet.new([:rotate, :press])}
      assert Control.has_capability?(control, :rotate)
      assert Control.has_capability?(control, :press)
    end

    test "returns false when capability is absent" do
      control = %Control{id: :knob, capabilities: MapSet.new([:rotate, :press])}
      refute Control.has_capability?(control, :display)
    end
  end

  describe "has_capabilities?/2" do
    test "returns true when all capabilities are present" do
      control = %Control{id: :key, capabilities: MapSet.new([:touch, :display, :haptic])}
      assert Control.has_capabilities?(control, [:touch, :display])
    end

    test "returns false when any capability is missing" do
      control = %Control{id: :key, capabilities: MapSet.new([:touch, :display])}
      refute Control.has_capabilities?(control, [:touch, :display, :led])
    end

    test "returns true for empty requirement list" do
      control = %Control{id: :key, capabilities: MapSet.new([:touch])}
      assert Control.has_capabilities?(control, [])
    end
  end
end
