defmodule Loupey.Driver.StreamdeckTest do
  use ExUnit.Case, async: true

  alias Loupey.Device.Variant.Classic
  alias Loupey.Driver.Streamdeck
  alias Loupey.Events.PressEvent
  alias Loupey.RenderCommands.{DrawBuffer, SetBrightness, SetLED}

  defp state, do: Streamdeck.new_driver_state()

  defp input_report(keys) when byte_size(keys) == 15 do
    <<0x01, 0x00, 0, 15>> <> keys
  end

  defp draw_buffer(key, jpeg) do
    %DrawBuffer{
      control_id: {:key, key},
      x: 0,
      y: 0,
      width: 72,
      height: 72,
      pixels: jpeg
    }
  end

  describe "Loupey.Driver callback bindings" do
    test "device_spec/0 delegates to Variant.Classic" do
      assert Streamdeck.device_spec() == Classic.device_spec()
    end

    test "matches?/1 delegates to Variant.Classic.is_variant?/1" do
      assert Streamdeck.matches?(%{vendor_id: 0x0FD9, product_id: 0x00B9})
      refute Streamdeck.matches?(%{vendor_id: 0x0FD9, product_id: 0x0060})
    end
  end

  describe "parse/2 — input reports" do
    test "emits :press for a key transitioning 0 → 1 from initial all-zeros state" do
      report = input_report(<<1::8, 0::size(14)-unit(8)>>)
      {_state, events} = Streamdeck.parse(state(), report)
      assert events == [%PressEvent{control_id: {:key, 0}, action: :press}]
    end

    test "emits :release for a key transitioning 1 → 0" do
      init = %{state() | keys: <<0, 0, 0, 1, 0::size(11)-unit(8)>>}
      report = input_report(<<0::size(15)-unit(8)>>)
      {_state, events} = Streamdeck.parse(init, report)
      assert events == [%PressEvent{control_id: {:key, 3}, action: :release}]
    end

    test "emits multiple press events in one report" do
      report = input_report(<<1, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1>>)
      {_state, events} = Streamdeck.parse(state(), report)

      assert events == [
               %PressEvent{control_id: {:key, 0}, action: :press},
               %PressEvent{control_id: {:key, 2}, action: :press},
               %PressEvent{control_id: {:key, 14}, action: :press}
             ]
    end

    test "emits mixed press and release in one report" do
      init = %{state() | keys: <<0, 1, 0::size(13)-unit(8)>>}
      report = input_report(<<1, 0, 0::size(13)-unit(8)>>)
      {_state, events} = Streamdeck.parse(init, report)

      assert events == [
               %PressEvent{control_id: {:key, 0}, action: :press},
               %PressEvent{control_id: {:key, 1}, action: :release}
             ]
    end

    test "returns no events when key state is unchanged" do
      init = %{state() | keys: <<1, 0::size(14)-unit(8)>>}
      report = input_report(<<1, 0::size(14)-unit(8)>>)
      {_state, events} = Streamdeck.parse(init, report)
      assert events == []
    end

    test "updates state so a follow-up read diffs from the new baseline" do
      report = input_report(<<1, 0::size(14)-unit(8)>>)
      {s1, _} = Streamdeck.parse(state(), report)
      {_s2, events} = Streamdeck.parse(s1, report)
      assert events == []
    end

    test "ignores reports with a non-0x01 report ID" do
      init = state()
      weird = <<0x05, 0, 0, 0>> <> :binary.copy(<<0>>, 15)
      {s, events} = Streamdeck.parse(init, weird)
      assert s == init
      assert events == []
    end

    test "ignores short reports that don't match the input-report shape" do
      init = state()
      {s, events} = Streamdeck.parse(init, <<0x01, 0, 0>>)
      assert s == init
      assert events == []
    end

    test "treats any nonzero key byte as pressed (noise-tolerant)" do
      # Key 0 previously holds value 1 (pressed). A follow-up report
      # carries value 2 on the same key — still pressed. The parse should
      # emit no event and not raise, since both normalize to the same
      # pressed-state. Regression for a FunctionClauseError that bit us
      # when the diff used raw byte values.
      init = %{state() | keys: <<1, 0::size(14)-unit(8)>>}
      report = input_report(<<2, 0::size(14)-unit(8)>>)
      {s, events} = Streamdeck.parse(init, report)
      assert events == []
      # State is updated to the new bytes (contents don't matter, they'll
      # be normalized on the next diff).
      assert s.keys == <<2, 0::size(14)-unit(8)>>
    end
  end

  describe "encode/1 — DrawBuffer" do
    test "a JPEG that fits in one packet produces a single packet with done=1" do
      jpeg = :binary.copy(<<0xAA>>, 500)
      assert {:image_packets, [packet]} = Streamdeck.encode(draw_buffer(0, jpeg))
      assert byte_size(packet) == 1024

      <<0x02, 0x07, key_idx, done, len::little-16, page::little-16, body::binary-size(1016)>> =
        packet

      assert key_idx == 0
      assert done == 0x01
      assert len == 500
      assert page == 0
      assert binary_part(body, 0, 500) == jpeg
      assert binary_part(body, 500, 1016 - 500) == :binary.copy(<<0>>, 516)
    end

    test "a JPEG that spans three packets numbers pages monotonically with done only on the last" do
      jpeg = :binary.copy(<<0xCC>>, 2132)
      assert {:image_packets, packets} = Streamdeck.encode(draw_buffer(7, jpeg))
      assert length(packets) == 3

      [p0, p1, p2] = packets

      for p <- packets, do: assert(byte_size(p) == 1024)

      assert <<0x02, 0x07, 7, 0x00, 1016::little-16, 0::little-16, _::binary>> = p0
      assert <<0x02, 0x07, 7, 0x00, 1016::little-16, 1::little-16, _::binary>> = p1
      assert <<0x02, 0x07, 7, 0x01, 100::little-16, 2::little-16, _::binary>> = p2
    end

    test "a JPEG of exactly 1016 bytes produces one packet with len=1016 and done=1" do
      jpeg = :binary.copy(<<0xDD>>, 1016)
      assert {:image_packets, [packet]} = Streamdeck.encode(draw_buffer(14, jpeg))

      assert <<0x02, 0x07, 14, 0x01, 1016::little-16, 0::little-16, body::binary-size(1016)>> =
               packet

      assert body == jpeg
    end

    test "a JPEG of exactly 1017 bytes produces two packets (1016 + 1)" do
      jpeg = :binary.copy(<<0xEE>>, 1017)
      assert {:image_packets, [p0, p1]} = Streamdeck.encode(draw_buffer(3, jpeg))

      assert <<0x02, 0x07, 3, 0x00, 1016::little-16, 0::little-16, _::binary>> = p0
      assert <<0x02, 0x07, 3, 0x01, 1::little-16, 1::little-16, _::binary>> = p1
    end
  end

  describe "encode/1 — SetBrightness" do
    test "0.0 maps to percent 0" do
      assert {:feature_report, <<0x03, 0x08, 0, rest::binary>>} =
               Streamdeck.encode(%SetBrightness{level: 0.0})

      assert byte_size(rest) == 32 - 3
    end

    test "1.0 maps to percent 100" do
      assert {:feature_report, <<0x03, 0x08, 100, _::binary>>} =
               Streamdeck.encode(%SetBrightness{level: 1.0})
    end

    test "0.5 maps to percent 50" do
      assert {:feature_report, <<0x03, 0x08, 50, _::binary>>} =
               Streamdeck.encode(%SetBrightness{level: 0.5})
    end

    test "0.75 rounds to percent 75" do
      assert {:feature_report, <<0x03, 0x08, 75, _::binary>>} =
               Streamdeck.encode(%SetBrightness{level: 0.75})
    end

    test "values below 0.0 are clamped to 0" do
      assert {:feature_report, <<0x03, 0x08, 0, _::binary>>} =
               Streamdeck.encode(%SetBrightness{level: -0.5})
    end

    test "values above 1.0 are clamped to 100" do
      assert {:feature_report, <<0x03, 0x08, 100, _::binary>>} =
               Streamdeck.encode(%SetBrightness{level: 2.5})
    end

    test "output is always 32 bytes (feature report declared length)" do
      assert {:feature_report, bytes} = Streamdeck.encode(%SetBrightness{level: 0.5})
      assert byte_size(bytes) == 32
    end
  end

  describe "encode/1 — SetLED" do
    test "returns :unsupported (MK.2 has no separate LEDs)" do
      assert :unsupported = Streamdeck.encode(%SetLED{control_id: {:key, 0}, color: "#FF0000"})
    end
  end

  describe "send_command/2 — dispatch" do
    test ":unsupported short-circuits to :ok" do
      # The `pid` isn't touched in the :unsupported clause, so any value works.
      assert :ok = Streamdeck.send_command(self(), :unsupported)
    end

    # Note: the write_output / write_feature dispatch is exercised end-to-end
    # against HidTransport + FakeHidPort in test/loupey/driver/streamdeck/
    # hid_transport_test.exs. The dispatch logic here is a straight
    # pattern-match + pass-through — failure modes are covered there.
  end
end
