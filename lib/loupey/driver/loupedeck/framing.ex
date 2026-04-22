defmodule Loupey.Driver.Loupedeck.Framing do
  @moduledoc """
  WebSocket frame parser for Loupedeck UART communication.

  Implements the `Circuits.UART.Framing` behaviour to extract WebSocket
  frames from the UART byte stream. Only handles incoming frame parsing —
  outgoing framing is handled by the driver's write functions.

  Frames start with `0x82` followed by a 1-byte length. If the byte
  stream ever gets out of sync (corrupted bytes, connected mid-frame,
  device glitch), `extract_frames/2` drops bytes until it finds the
  next `0x82` marker. The buffer is capped at `max_length` — if it
  ever exceeds that (shouldn't happen given the resync, but defence
  in depth), drop it entirely and log.
  """
  @behaviour Circuits.UART.Framing

  require Logger

  defmodule State do
    @moduledoc false
    defstruct [:max_length, buffer: <<>>]
  end

  @impl true
  def init(_args), do: {:ok, %State{max_length: 14_096}}

  @impl true
  def add_framing(data, state), do: {:ok, data, state}

  @impl true
  def remove_framing(data, state) do
    {buffer, frames} =
      state.buffer
      |> Kernel.<>(data)
      |> extract_frames([])

    buffer = cap_buffer(buffer, state.max_length)

    new_state = %{state | buffer: buffer}
    rc = if new_state.buffer == <<>>, do: :ok, else: :in_frame
    {rc, frames, new_state}
  end

  @impl true
  def frame_timeout(state), do: {:ok, [], %{state | buffer: <<>>}}

  @impl true
  def flush(direction, state) when direction in [:receive, :both] do
    %{state | buffer: <<>>}
  end

  def flush(:transmit, state), do: state

  # Empty buffer → done.
  defp extract_frames(<<>>, acc), do: {<<>>, Enum.reverse(acc)}

  # Full frame available: emit it and recurse. Prepend + reverse-on-return
  # avoids quadratic `acc ++ [frame]` cost when many frames arrive at once.
  defp extract_frames(<<0x82, len, rest::binary>>, acc) when byte_size(rest) >= len do
    <<frame::binary-size(len), remaining::binary>> = rest
    extract_frames(remaining, [frame | acc])
  end

  # Marker present but waiting for more body bytes. Hold the buffer as-is.
  defp extract_frames(<<0x82, _::binary>> = buffer, acc) do
    {buffer, Enum.reverse(acc)}
  end

  # Non-`0x82` leading byte — resync to the next marker via a single
  # binary-match scan. Anything before the next marker is junk and
  # dropped. If there's no marker anywhere in the remaining buffer,
  # drop the whole thing.
  defp extract_frames(buffer, acc) do
    case :binary.match(buffer, <<0x82>>) do
      :nomatch ->
        {<<>>, Enum.reverse(acc)}

      {pos, _} ->
        <<_junk::binary-size(pos), from_marker::binary>> = buffer
        extract_frames(from_marker, acc)
    end
  end

  # Post-extract, the buffer can only contain a partial frame headed by
  # `0x82`, so its size is bounded by `1 + 1 + 255 = 257` bytes in
  # practice. This cap is belt-and-suspenders against any extraction bug
  # that could let it grow unbounded — if tripped, drop everything and
  # log so the condition is observable.
  defp cap_buffer(buffer, max_length) when byte_size(buffer) <= max_length, do: buffer

  defp cap_buffer(buffer, max_length) do
    Logger.warning(
      "Loupedeck.Framing buffer grew to #{byte_size(buffer)} bytes " <>
        "(cap: #{max_length}); dropping — stream likely corrupted"
    )

    <<>>
  end
end
