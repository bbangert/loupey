defmodule Loupey.Driver.Loupedeck.Connection do
  @moduledoc """
  Per-device connection GenServer for the Loupedeck driver.

  Owns the UART port, the WebSocket-over-UART framing, the 0x82 outgoing
  frame wrapper, payload chunking, and the transaction-ID counter. Forwards
  incoming decoded Loupedeck frames to the parent pid as
  `{:device_data, bytes}`.
  """

  use GenServer
  require Logger

  @ws_upgrade_header "GET /index.html\nHTTP/1.1\nConnection: Upgrade\nUpgrade: websocket\nSec-WebSocket-Key: 123abc\n\n"
  @ws_close_frame <<0x88, 0x80, 0x00, 0x00, 0x00, 0x00>>

  defmodule State do
    @moduledoc false
    defstruct [:parent, :uart_pid, :tty, transaction_id: 0]
  end

  # -- Public API --

  @doc """
  Start the connection. `opts` must include `:parent` — the pid that will
  receive `{:device_data, binary}` messages from the device.
  """
  @spec start_link(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(tty, opts) do
    parent = Keyword.fetch!(opts, :parent)
    GenServer.start_link(__MODULE__, {tty, parent})
  end

  # UART writes should complete in well under a millisecond; 5 s is a
  # "something is genuinely wrong" bound — timeout raises in the caller
  # (DeviceServer), which its supervisor restarts cleanly.
  @send_timeout_ms 5_000

  @doc """
  Frame, chunk, and write an encoded command to the device.
  """
  @spec send_command(pid(), {byte(), binary()}) :: :ok | {:error, term()}
  def send_command(pid, {cmd_byte, payload}) do
    GenServer.call(pid, {:send_command, cmd_byte, payload}, @send_timeout_ms)
  end

  @doc """
  Close the connection and stop the GenServer.
  """
  @spec close(pid()) :: :ok
  def close(pid) do
    GenServer.stop(pid, :normal)
  end

  # -- GenServer callbacks --

  @impl true
  def init({tty, parent}) do
    Process.flag(:trap_exit, true)

    case open_uart(tty) do
      {:ok, uart_pid} ->
        {:ok, %State{parent: parent, uart_pid: uart_pid, tty: tty}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:send_command, cmd_byte, payload}, _from, state) do
    {tid, state} = next_tid(state)
    buffer = format_message(tid, cmd_byte, payload)
    result = write_framed(state.uart_pid, buffer)
    {:reply, result, state}
  end

  @impl true
  def handle_info({:circuits_uart, _tty, data}, state) when is_binary(data) do
    send(state.parent, {:device_data, data})
    {:noreply, state}
  end

  def handle_info({:circuits_uart, _tty, {:error, reason}}, state) do
    Logger.warning("UART error from #{state.tty}: #{inspect(reason)}")
    {:stop, {:uart_error, reason}, state}
  end

  # The linked UART port died — stop so the supervisor can restart us with
  # a fresh port. `terminate/2` runs force_cleanup on the already-dead pid,
  # which is a no-op after the catch blocks in force_cleanup/1.
  def handle_info({:EXIT, uart_pid, reason}, %State{uart_pid: uart_pid} = state) do
    Logger.warning("UART process exited from #{state.tty}: #{inspect(reason)}")
    {:stop, {:uart_exited, reason}, state}
  end

  # Our parent DeviceServer died — no one left to serve, shut down.
  def handle_info({:EXIT, parent, reason}, %State{parent: parent} = state) do
    {:stop, reason, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    force_cleanup(state.uart_pid)
    :ok
  end

  # -- Internals --

  defp open_uart(tty) do
    case Circuits.UART.start_link() do
      {:ok, uart_pid} -> configure_uart(uart_pid, tty)
      {:error, _} = error -> error
    end
  end

  defp configure_uart(uart_pid, tty) do
    try do
      with :ok <- Circuits.UART.open(uart_pid, tty, speed: 256_000, active: false),
           # Send a WebSocket close frame first in case the device is still in
           # an active session from a prior unclean disconnect.
           :ok <- Circuits.UART.write(uart_pid, @ws_close_frame),
           # Small delay to let the device process the close and reset.
           _ <- Process.sleep(50),
           _ <- drain_uart(uart_pid),
           :ok <- Circuits.UART.write(uart_pid, @ws_upgrade_header),
           {:ok, _upgrade_response} <- Circuits.UART.read(uart_pid, 2000),
           _ <- drain_uart(uart_pid),
           :ok <-
             Circuits.UART.configure(uart_pid,
               framing: {Loupey.Driver.Loupedeck.Framing, []},
               active: true
             ) do
        {:ok, uart_pid}
      else
        {:error, _} = error ->
          force_cleanup(uart_pid)
          error
      end
    rescue
      e ->
        force_cleanup(uart_pid)
        {:error, e}
    end
  end

  defp drain_uart(uart_pid) do
    case Circuits.UART.read(uart_pid, 100) do
      {:ok, ""} -> :ok
      {:ok, _data} -> drain_uart(uart_pid)
      {:error, :etimedout} -> :ok
      _ -> :ok
    end
  end

  defp force_cleanup(uart_pid) when is_pid(uart_pid) do
    try do
      Circuits.UART.write(uart_pid, @ws_close_frame)
    catch
      kind, err ->
        Logger.debug(
          "Loupedeck.Connection.force_cleanup: UART op raised (ignored): #{kind} #{inspect(err)}"
        )

        :ok
    end

    try do
      Circuits.UART.close(uart_pid)
    catch
      kind, err ->
        Logger.debug(
          "Loupedeck.Connection.force_cleanup: UART op raised (ignored): #{kind} #{inspect(err)}"
        )

        :ok
    end

    try do
      Circuits.UART.stop(uart_pid)
    catch
      kind, err ->
        Logger.debug(
          "Loupedeck.Connection.force_cleanup: UART op raised (ignored): #{kind} #{inspect(err)}"
        )

        :ok
    end
  end

  defp force_cleanup(_), do: :ok

  # Transaction IDs rotate 1..255 (never 0).
  defp next_tid(%State{transaction_id: tid} = state) do
    next = rem(tid, 255) + 1
    {next, %{state | transaction_id: next}}
  end

  defp format_message(transaction_id, command, data) when is_binary(data) do
    <<min(3 + byte_size(data), 0xFF)::8, command, transaction_id, data::binary>>
  end

  defp format_message(transaction_id, command, data) do
    <<4, command, transaction_id, data>>
  end

  defp write_framed(uart_pid, buffer) when byte_size(buffer) <= 0xFF do
    Circuits.UART.write(uart_pid, [<<0x82, 0x80 + byte_size(buffer), 0x00::32>>, buffer])
  end

  defp write_framed(uart_pid, buffer) do
    header = <<0x82, 0xFF, 0x00::32, byte_size(buffer)::unsigned-integer-32, 0x00::32>>

    with :ok <- Circuits.UART.write(uart_pid, header) do
      write_chunks(uart_pid, buffer)
    end
  end

  defp write_chunks(uart_pid, buffer) when byte_size(buffer) <= 15_300 do
    Circuits.UART.write(uart_pid, buffer)
  end

  defp write_chunks(uart_pid, buffer) do
    <<chunk::binary-size(15_300), rest::binary>> = buffer

    with :ok <- Circuits.UART.write(uart_pid, chunk) do
      write_chunks(uart_pid, rest)
    end
  end
end
