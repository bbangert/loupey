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
    defstruct [:parent, :uart_pid, :tty, :port, transaction_id: 0, bytes_seen: 0, stuck_count: 0]
  end

  # Liveness watchdog. The C-side port driver can land in a state where
  # `Port.info(port, :input)` keeps incrementing (the kernel is still
  # delivering serial bytes) but the Circuits.UART gen_server never
  # produces a corresponding `{:circuits_uart, _, _}` message. The device
  # silently looks dead. A full BEAM restart clears it; killing only the
  # supervised subtree from the same BEAM also recovers.
  #
  # Detection: every `@health_check_interval_ms`, send a benign `:serial`
  # probe and snapshot both counters. After `@health_check_window_ms`,
  # compare deltas: `port_delta > 0 && bytes_delta == 0` means bytes
  # arrived at the port but never made it through to us. Two consecutive
  # bad checks → `{:stop, :uart_stuck, state}` so the DynamicSupervisor
  # rebuilds the chain.
  @health_check_interval_ms 15_000
  # Generous enough to cover the full probe response — the init handshake
  # uses the same 2s budget for its initial `Circuits.UART.read/2`. A
  # `:serial` response is ~30 bytes and arrives in multiple UART chunks;
  # 500 ms windows the start-of-frame in but cuts off before the rest is
  # framed, producing false stuck-checks.
  @health_check_window_ms 2_000
  @max_consecutive_stuck 2

  # 0x03 = :serial. The device always replies with its serial number;
  # the driver's `parse/2` returns `[]` for the response (no event
  # emitted, no side effects).
  @health_probe_command 0x03

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
        schedule_health_check()
        {:ok, %State{parent: parent, uart_pid: uart_pid, tty: tty, port: uart_port(uart_pid)}}

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
    {:noreply, %{state | bytes_seen: state.bytes_seen + byte_size(data)}}
  end

  def handle_info({:circuits_uart, _tty, {:error, reason}}, state) do
    Logger.warning("UART error from #{state.tty}: #{inspect(reason)}")
    {:stop, {:uart_error, reason}, state}
  end

  def handle_info(:health_check, state) do
    prev_port = port_input(state.port)
    prev_seen = state.bytes_seen
    # `next_tid` because transaction_id 0 is reserved/anomalous — using
    # it can produce truncated or unanswered responses.
    {tid, state} = next_tid(state)

    # Most write failures take the linked UART process down with them and
    # would surface as `{:EXIT, ...}` below — but a write returning
    # `{:error, _}` without the gen_server exiting (transient I/O error,
    # kernel-side EAGAIN, etc.) would otherwise leave both deltas at zero
    # and look healthy. Exit immediately so the supervisor restarts —
    # symmetric with the `{:circuits_uart, _, {:error, _}}` clause above.
    case write_framed(state.uart_pid, format_message(tid, @health_probe_command, <<>>)) do
      :ok ->
        Process.send_after(
          self(),
          {:health_check_eval, prev_port, prev_seen},
          @health_check_window_ms
        )

        {:noreply, state}

      {:error, reason} ->
        Logger.warning(
          "Loupedeck #{state.tty}: health probe write failed " <>
            "(#{inspect(reason)}). Exiting for supervisor restart."
        )

        {:stop, {:health_probe_write_failed, reason}, state}
    end
  end

  def handle_info({:health_check_eval, prev_port, prev_seen}, state) do
    port_delta = port_input(state.port) - prev_port
    bytes_delta = state.bytes_seen - prev_seen

    if port_delta > 0 and bytes_delta == 0 do
      handle_stuck_check(state, port_delta)
    else
      schedule_health_check()
      {:noreply, %{state | stuck_count: 0}}
    end
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

  defp schedule_health_check do
    Process.send_after(self(), :health_check, @health_check_interval_ms)
  end

  # Circuits.UART links its C port to its own gen_server. There's always
  # exactly one port in the links list once `Circuits.UART.open/3` succeeds.
  defp uart_port(uart_pid) do
    case Process.info(uart_pid, :links) do
      {:links, links} -> Enum.find(links, &is_port/1)
      _ -> nil
    end
  end

  # `Port.info(port, :input)` returns `{:input, n}` while the port is
  # alive, `nil` or `:undefined` once it closes. Treat absence as 0 so
  # any subsequent delta against a fresh sample looks healthy rather
  # than triggering a false stuck-check on a port that's dying anyway —
  # the EXIT handler will stop us in that case.
  defp port_input(nil), do: 0

  defp port_input(port) do
    case Port.info(port, :input) do
      {:input, n} -> n
      _ -> 0
    end
  end

  defp handle_stuck_check(state, port_delta) do
    stuck = state.stuck_count + 1

    if stuck >= @max_consecutive_stuck do
      Logger.error(
        "Loupedeck #{state.tty}: UART stuck (#{stuck} consecutive checks; " <>
          "port=+#{port_delta}b, erlang=0b). Exiting for supervisor restart."
      )

      {:stop, :uart_stuck, state}
    else
      Logger.warning(
        "Loupedeck #{state.tty}: UART possibly stuck (#{stuck}/#{@max_consecutive_stuck}; " <>
          "port=+#{port_delta}b, erlang=0b). Re-probing."
      )

      schedule_health_check()
      {:noreply, %{state | stuck_count: stuck}}
    end
  end

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
