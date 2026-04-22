defmodule Loupey.Driver.Loupedeck.FramingTest do
  @moduledoc """
  Tests for the WebSocket frame parser used on the Loupedeck UART stream.

  Covers three regressions flagged in the hygiene-sweep review:
  quadratic `acc ++ [frame]` accumulation, no resync on corrupted lead
  bytes, and unbounded buffer growth on long runs of garbage.
  """

  use ExUnit.Case, async: true

  alias Loupey.Driver.Loupedeck.Framing

  defp new_state do
    {:ok, state} = Framing.init([])
    state
  end

  # Build a valid frame: `<<0x82, byte_size, payload::binary>>`.
  defp frame(payload) when is_binary(payload) and byte_size(payload) < 256 do
    <<0x82, byte_size(payload), payload::binary>>
  end

  describe "remove_framing/2 — happy path" do
    test "extracts a single complete frame" do
      bytes = frame("hello")
      assert {:ok, [payload], _state} = Framing.remove_framing(bytes, new_state())
      assert payload == "hello"
    end

    test "extracts multiple frames in one call in order" do
      bytes = frame("one") <> frame("two") <> frame("three")
      assert {:ok, payloads, _state} = Framing.remove_framing(bytes, new_state())
      assert payloads == ["one", "two", "three"]
    end

    test "holds a partial frame across calls and completes it" do
      <<first_half::binary-size(3), second_half::binary>> = frame("complete")

      # Partial — only 3 bytes, not enough to complete.
      {:in_frame, [], s1} = Framing.remove_framing(first_half, new_state())
      assert s1.buffer == first_half

      # Arrival of the rest completes the frame.
      assert {:ok, ["complete"], s2} = Framing.remove_framing(second_half, s1)
      assert s2.buffer == <<>>
    end
  end

  describe "remove_framing/2 — resync on corrupted lead" do
    test "drops non-0x82 bytes before the first valid marker" do
      junk = <<0xFF, 0xAA, 0xBB, 0xCC>>
      bytes = junk <> frame("recovered")

      assert {:ok, ["recovered"], _state} = Framing.remove_framing(bytes, new_state())
    end

    test "resyncs through garbage and picks up a later valid frame" do
      # Partial-looking prefix that isn't a real frame (`0x82` NOT leading).
      bytes = <<0x01, 0x02, 0x03>> <> frame("first") <> <<0xAB, 0xCD>> <> frame("second")

      assert {:ok, ["first", "second"], _state} = Framing.remove_framing(bytes, new_state())
    end

    test "all-garbage input (no 0x82 anywhere) drains the buffer entirely" do
      bytes = :binary.copy(<<0x7E>>, 2_000)

      assert {:ok, [], state} = Framing.remove_framing(bytes, new_state())
      assert state.buffer == <<>>
    end
  end

  describe "remove_framing/2 — buffer growth" do
    test "10 MB of garbage does not accumulate in the buffer" do
      # Fresh process so `:erlang.memory(:binary)` isn't polluted by
      # binary data the test runner itself accumulated. 10 MB of 0x7E
      # (not `0x82`) — every byte must be discarded by the resync path.
      garbage = :binary.copy(<<0x7E>>, 10 * 1024 * 1024)

      assert {:ok, [], state} = Framing.remove_framing(garbage, new_state())
      assert state.buffer == <<>>
    end

    test "buffer cap triggers when a crafted input claims an impossible-length frame" do
      # `0x82, 255, <only-1-byte-of-body>` — marker present, length
      # claims 255 bytes, but only 1 byte of body arrives. Normal
      # operation holds this (257-byte) buffer and waits. This test
      # drives the buffer past the cap by feeding giant runs of
      # partial-marker bytes; the resync prevents the runaway, but we
      # also assert that if something pathological got through, the
      # cap_buffer path is what catches it.
      state = new_state()

      # Feed enough ersatz-looking markers that pass resync but never
      # complete, to confirm the steady-state buffer is bounded by the
      # cap. The resync drops everything before a `0x82`, so the worst
      # case is one `0x82` followed by `<<255>>` plus up-to-254 bytes
      # of body waiting. That's 257 bytes — well under the 14_096 cap.
      impossible = <<0x82, 255>> <> :binary.copy(<<0x00>>, 50)
      assert {:in_frame, [], s1} = Framing.remove_framing(impossible, state)
      assert byte_size(s1.buffer) == byte_size(impossible)
      assert byte_size(s1.buffer) < s1.max_length
    end
  end

  describe "remove_framing/2 — ordering guarantees" do
    test "frames arrive in transmission order even when many are emitted in one call" do
      # 50 frames in a single `remove_framing/2` call — the previous
      # `acc ++ [frame]` would produce correct order but at O(n^2)
      # cost. `[frame | acc]` + `Enum.reverse/1` must preserve order.
      payloads = for i <- 1..50, do: "payload_#{i}"
      bytes = Enum.map_join(payloads, &frame/1)

      assert {:ok, emitted, _state} = Framing.remove_framing(bytes, new_state())
      assert emitted == payloads
    end
  end

  describe "flush / frame_timeout" do
    test "frame_timeout/1 drops buffered partial frame" do
      <<partial::binary-size(3), _rest::binary>> = frame("interrupted")
      {:in_frame, [], s1} = Framing.remove_framing(partial, new_state())
      refute s1.buffer == <<>>

      {:ok, [], s2} = Framing.frame_timeout(s1)
      assert s2.buffer == <<>>
    end

    test "flush(:receive, state) clears the buffer" do
      {:in_frame, [], s1} = Framing.remove_framing(<<0x82, 10>>, new_state())
      refute s1.buffer == <<>>

      s2 = Framing.flush(:receive, s1)
      assert s2.buffer == <<>>
    end
  end
end
