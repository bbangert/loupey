defmodule Loupey.Driver.Loupedeck.Framing do
  @moduledoc """
  WebSocket frame parser for Loupedeck UART communication.

  Implements the `Circuits.UART.Framing` behaviour to extract WebSocket
  frames from the UART byte stream. Only handles incoming frame parsing —
  outgoing framing is handled by the driver's write functions.
  """
  @behaviour Circuits.UART.Framing

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

  defp extract_frames(<<0x82, len, rest::binary>>, acc) when byte_size(rest) >= len do
    <<frame::binary-size(len), remaining::binary>> = rest
    extract_frames(remaining, acc ++ [frame])
  end

  defp extract_frames(buffer, acc), do: {buffer, acc}
end
