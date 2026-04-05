defmodule Loupey.Driver.LoupedeckTest do
  use ExUnit.Case, async: true

  alias Loupey.Device.Spec
  alias Loupey.Driver.Loupedeck
  alias Loupey.Events.{PressEvent, RotateEvent, TouchEvent}
  alias Loupey.RenderCommands.{SetBrightness, SetLED}

  defp driver_state, do: Loupedeck.new_driver_state()

  describe "matches?/1" do
    test "matches Loupedeck Live by vendor/product ID" do
      assert Loupedeck.matches?(%{vendor_id: 0x2EC2, product_id: 0x0004})
    end

    test "rejects unknown device" do
      refute Loupedeck.matches?(%{vendor_id: 0x1234, product_id: 0x5678})
    end
  end

  describe "device_spec/0" do
    test "returns a spec with controls" do
      spec = Loupedeck.device_spec()
      assert spec.type == "Loupedeck Live"
      assert spec.controls != []
    end

    test "spec includes knobs with rotate and press" do
      spec = Loupedeck.device_spec()
      knob = Spec.find_control(spec, :knob_tl)
      assert knob
      assert MapSet.member?(knob.capabilities, :rotate)
      assert MapSet.member?(knob.capabilities, :press)
    end

    test "spec includes display keys" do
      spec = Loupedeck.device_spec()
      key = Spec.find_control(spec, {:key, 0})
      assert key
      assert MapSet.member?(key.capabilities, :touch)
      assert MapSet.member?(key.capabilities, :display)
      assert key.display.width == 90
      assert key.display.pixel_format == :rgb565
    end

    test "spec includes LED buttons" do
      spec = Loupedeck.device_spec()
      btn = Spec.find_control(spec, {:button, 0})
      assert btn
      assert MapSet.member?(btn.capabilities, :press)
      assert MapSet.member?(btn.capabilities, :led)
    end

    test "spec includes strips" do
      spec = Loupedeck.device_spec()
      left = Spec.find_control(spec, :left_strip)
      assert left
      assert left.display.width == 60
      assert left.display.height == 270
    end
  end

  describe "parse/2 - button press" do
    test "parses button press down" do
      # Command 0x00 (button_press), transaction_id 1, hw_id 0x07 (button 0), 0x00 (down)
      raw = <<1, 0x00, 1, 0x07, 0x00>>
      {_state, events} = Loupedeck.parse(driver_state(), raw)
      assert [%PressEvent{control_id: {:button, 0}, action: :press}] = events
    end

    test "parses button release" do
      raw = <<1, 0x00, 1, 0x07, 0x01>>
      {_state, events} = Loupedeck.parse(driver_state(), raw)
      assert [%PressEvent{control_id: {:button, 0}, action: :release}] = events
    end

    test "parses knob press" do
      # hw_id 0x01 = knob_tl
      raw = <<1, 0x00, 1, 0x01, 0x00>>
      {_state, events} = Loupedeck.parse(driver_state(), raw)
      assert [%PressEvent{control_id: :knob_tl, action: :press}] = events
    end
  end

  describe "parse/2 - knob rotate" do
    test "parses clockwise rotation" do
      # Command 0x01 (knob_rotate), hw_id 0x01 (knob_tl), delta 1 (cw)
      raw = <<1, 0x01, 1, 0x01, 1>>
      {_state, events} = Loupedeck.parse(driver_state(), raw)
      assert [%RotateEvent{control_id: :knob_tl, direction: :cw}] = events
    end

    test "parses counter-clockwise rotation" do
      raw = <<1, 0x01, 1, 0x01, 0xFF>>
      {_state, events} = Loupedeck.parse(driver_state(), raw)
      assert [%RotateEvent{control_id: :knob_tl, direction: :ccw}] = events
    end
  end

  describe "parse/2 - touch" do
    test "parses touch start on center key" do
      # Command 0x4D (touch), x=100 (in key 0 area), y=45, touch_id=0
      raw = <<1, 0x4D, 1, 0x00, 0x00, 0x64, 0x00, 0x2D, 0x00>>
      {state, events} = Loupedeck.parse(driver_state(), raw)
      assert [%TouchEvent{control_id: {:key, _}, action: :start}] = events
      assert map_size(state.touches) == 1
    end

    test "parses touch end" do
      # First touch start
      raw_start = <<1, 0x4D, 1, 0x00, 0x00, 0x64, 0x00, 0x2D, 0x00>>
      {state, _} = Loupedeck.parse(driver_state(), raw_start)

      # Then touch end (command 0x6D)
      raw_end = <<1, 0x6D, 2, 0x00, 0x00, 0x64, 0x00, 0x2D, 0x00>>
      {state, events} = Loupedeck.parse(state, raw_end)
      assert [%TouchEvent{action: :end}] = events
      assert map_size(state.touches) == 0
    end

    test "touch coordinates are local to control" do
      # Touch at absolute x=100, y=45. Key 0 has offset {60, 0}.
      # Local coords should be x=40, y=45.
      raw = <<1, 0x4D, 1, 0x00, 0x00, 0x64, 0x00, 0x2D, 0x00>>
      {_state, [event]} = Loupedeck.parse(driver_state(), raw)
      assert event.x == 40
      assert event.y == 45
    end

    test "parses touch on left strip" do
      # Touch at x=30, y=100 — should be left strip
      raw = <<1, 0x4D, 1, 0x00, 0x00, 0x1E, 0x00, 0x64, 0x00>>
      {_state, events} = Loupedeck.parse(driver_state(), raw)
      assert [%TouchEvent{control_id: :left_strip}] = events
    end
  end

  describe "encode/1" do
    test "encodes SetLED command" do
      cmd = %SetLED{control_id: {:button, 0}, color: "#FF0000"}
      {cmd_byte, payload} = Loupedeck.encode(cmd)
      assert cmd_byte == 0x02
      assert <<0x07, 255, 0, 0>> = payload
    end

    test "encodes SetBrightness command" do
      cmd = %SetBrightness{level: 0.5}
      {cmd_byte, payload} = Loupedeck.encode(cmd)
      assert cmd_byte == 0x09
      assert payload == 5
    end
  end
end
