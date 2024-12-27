defmodule Loupey.Framing.Websocket do
  @behaviour Circuits.UART.Framing

  defmodule State do
    @moduledoc false
    defstruct [:max_length, buffer: <<>>]
  end

  def init(_args), do: {:ok, %State{max_length: 14096}}

  # Unfortunately the framing behaviour is not well suited for payloads
  # that need multiple write's to be completed due to size restrictions
  # on each UART write. Actual websocket framing is done in the
  # DeviceHandler.
  def add_framing(data, state), do: {:ok, data, state}

  def remove_framing(data, state) do
    {buffer, ws_frames} =
      process_data(
        state.max_length,
        state.buffer <> data,
        []
      )

    new_state = %{state | buffer: buffer}
    rc = if buffer_empty?(new_state), do: :ok, else: :in_frame
    {rc, ws_frames, new_state}
  end

  def frame_timeout(state), do: {:ok, [], %{state | buffer: <<>>}}

  def flush(direction, state) when direction == :receive or direction == :both do
    %{state | buffer: <<>>}
  end

  def flush(:transmit, state) do
    state
  end

  def buffer_empty?(%State{buffer: <<>>}), do: true
  def buffer_empty?(_state), do: false

  def process_data(max_length, buffer, ws_frames) do
    case buffer do
      # We have enough data for a full frame
      <<0x82, len, rest::binary>> when byte_size(rest) >= len ->
        <<frame::binary-size(len), rest::binary>> = rest
        ws_frames = ws_frames ++ [frame]
        process_data(max_length, rest, ws_frames)

      # We have a partial frame, return what we did get
      _ ->
        {buffer, ws_frames}
    end
  end
end
