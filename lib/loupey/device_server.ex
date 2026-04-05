defmodule Loupey.DeviceServer do
  @moduledoc """
  GenServer that manages a single connected device.

  This is a thin wrapper around a `Loupey.Driver` implementation. It:
  - Connects to the device via the driver
  - Parses incoming raw data into normalized `Loupey.Events` and broadcasts via PubSub
  - Accepts `Loupey.RenderCommands`, encodes them via the driver, and sends to the device

  All protocol logic lives in the driver module. All business logic lives in the
  binding engine (M3). This server is just the I/O boundary.
  """

  use GenServer
  require Logger

  defmodule State do
    @moduledoc false
    defstruct [
      :driver_module,
      :connection,
      :driver_state,
      :spec,
      :device_id,
      transaction_id: 0,
      pending_transactions: %{}
    ]
  end

  # -- Public API --

  def start_link(opts) do
    driver_module = Keyword.fetch!(opts, :driver)
    tty = Keyword.fetch!(opts, :tty)
    device_id = Keyword.get(opts, :device_id, tty)
    GenServer.start_link(__MODULE__, {driver_module, tty, device_id}, name: via_tuple(device_id))
  end

  @doc """
  Send a render command to the device.
  """
  @spec render(term(), Loupey.RenderCommands.t()) :: :ok
  def render(device_id, command) do
    GenServer.cast(via_tuple(device_id), {:render, command})
  end

  @doc """
  Send a render command and refresh the display.
  """
  @spec render_and_refresh(term(), Loupey.RenderCommands.t(), binary()) :: :ok
  def render_and_refresh(device_id, command, display_id) do
    GenServer.cast(via_tuple(device_id), {:render_and_refresh, command, display_id})
  end

  @doc """
  Refresh a display after drawing. The display_id is the raw binary display
  identifier from the control's display spec.
  """
  @spec refresh(term(), binary()) :: :ok
  def refresh(device_id, display_id) do
    GenServer.cast(via_tuple(device_id), {:refresh, display_id})
  end

  @doc """
  Get the device spec.
  """
  @spec get_spec(term()) :: Loupey.Device.Spec.t()
  def get_spec(device_id) do
    GenServer.call(via_tuple(device_id), :get_spec)
  end

  defp via_tuple(device_id) do
    {:via, Registry, {Loupey.DeviceRegistry, device_id}}
  end

  # -- GenServer callbacks --

  @impl true
  def init({driver_module, tty, device_id}) do
    case driver_module.connect(tty) do
      {:ok, connection} ->
        spec = driver_module.device_spec()

        driver_state =
          if function_exported?(driver_module, :new_driver_state, 0) do
            driver_module.new_driver_state()
          else
            %{}
          end

        {:ok,
         %State{
           driver_module: driver_module,
           connection: connection,
           driver_state: driver_state,
           spec: spec,
           device_id: device_id
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:get_spec, _from, state) do
    {:reply, state.spec, state}
  end

  @impl true
  def handle_cast({:render, command}, state) do
    send_command(state, command)
    {:noreply, state}
  end

  def handle_cast({:render_and_refresh, command, display_id}, state) do
    send_command(state, command)
    send_encoded(state, state.driver_module.encode_refresh(display_id))
    {:noreply, state}
  end

  def handle_cast({:refresh, display_id}, state) do
    send_encoded(state, state.driver_module.encode_refresh(display_id))
    {:noreply, state}
  end

  @impl true
  def handle_info({:circuits_uart, _tty, data}, state) when is_binary(data) do
    {driver_state, events} = state.driver_module.parse(state.driver_state, data)
    state = %{state | driver_state: driver_state}

    Enum.each(events, fn event ->
      Logger.debug("Device event: #{inspect(event)}")
      broadcast_event(state.device_id, event)
    end)

    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    try do
      state.driver_module.disconnect(state.connection)
    catch
      _, _ -> :ok
    end

    :ok
  end

  # -- Internals --

  defp send_command(state, command) do
    {cmd_byte, payload} = state.driver_module.encode(command)
    buffer = format_message(next_tid(state), cmd_byte, payload)
    write_framed(state.connection, buffer)
  end

  defp send_encoded(state, {cmd_byte, payload}) do
    buffer = format_message(next_tid(state), cmd_byte, payload)
    write_framed(state.connection, buffer)
  end

  defp next_tid(state) do
    rem(state.transaction_id + 1, 256) |> max(1)
  end

  defp format_message(transaction_id, command, data) when is_binary(data) do
    <<min(3 + byte_size(data), 0xFF)::8, command, transaction_id, data::binary>>
  end

  defp format_message(transaction_id, command, data) do
    <<4, command, transaction_id, data>>
  end

  defp write_framed(%{uart_pid: uart_pid} = _conn, buffer) when byte_size(buffer) <= 0xFF do
    Circuits.UART.write(uart_pid, [<<0x82, 0x80 + byte_size(buffer), 0x00::32>>, buffer])
  end

  defp write_framed(%{uart_pid: uart_pid} = conn, buffer) do
    header = <<0x82, 0xFF, 0x00::32, byte_size(buffer)::unsigned-integer-32, 0x00::32>>
    Circuits.UART.write(uart_pid, header)
    write_chunks(conn, buffer)
  end

  defp write_chunks(%{uart_pid: uart_pid}, buffer) when byte_size(buffer) <= 15300 do
    Circuits.UART.write(uart_pid, buffer)
  end

  defp write_chunks(%{uart_pid: uart_pid} = conn, buffer) do
    <<chunk::binary-size(15300), rest::binary>> = buffer
    Circuits.UART.write(uart_pid, chunk)
    if byte_size(rest) > 0, do: write_chunks(conn, rest)
  end

  defp broadcast_event(device_id, event) do
    Registry.dispatch(Loupey.EventRegistry, device_id, fn entries ->
      for {pid, _value} <- entries, do: send(pid, {:device_event, device_id, event})
    end)
  end
end
