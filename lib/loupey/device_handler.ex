defmodule Loupey.DeviceHandler do
  @moduledoc """
  Server process that handles communication with a Loupedeck device using the provided
  handler module.
  """
  use GenServer

  require Logger

  @ws_upgrade_header "GET /index.html\nHTTP/1.1\nConnection: Upgrade\nUpgrade: websocket\nSec-WebSocket-Key: 123abc\n\n"
  @ws_close_frame <<0x88, 0x80, 0x00, 0x00, 0x00, 0x00>>

  defmodule State do
    @moduledoc false

    defstruct [
      :device,
      :uarts_pid,
      :handler_pid,
      :handler,
      transaction_id: 0,
      pending_transactions: %{}
    ]
  end

  # Public API

  def start_link({device, handler}) do
    GenServer.start_link(__MODULE__, {device, handler})
  end

  def stop(pid) do
    GenServer.stop(pid)
  end

  @doc """
  Set the brightness of the display. The value should be between 0 and 1 in increments of 0.1.
  """
  def set_brightness(pid, value) do
    GenServer.call(pid, {:set_brightness, value})
  end

  @doc """
  Set the color of a button.

  Parameters:
    * `id` - The button id.
    * `color` - The color as a string in the format "#RRGGBB".
  """
  @spec set_button_color(pid(), Loupey.Device.button_number(), String.t()) :: any()
  def set_button_color(pid, id, color) do
    GenServer.call(pid, {:set_button_color, id, color})
  end

  def draw_buffer(pid, id, width, height, x, y, buffer) do
    GenServer.call(pid, {:draw_buffer, id, width, height, x, y, buffer})
  end

  @spec draw_image(pid(), Loupey.Device.button_number(), Loupey.Image.t()) :: any()
  def draw_image(pid, button_id, image) do
    GenServer.call(pid, {:draw_image, button_id, image})
  end

  def fill_key(pid, id, color) do
    GenServer.call(pid, {:fill_key, id, color})
  end

  @spec fill_slider(pid(), :left | :right, String.t()) :: any()
  def fill_slider(pid, id, color, percent \\ 100) do
    GenServer.call(pid, {:fill_slider, id, color, percent})
  end

  @spec refresh(pid(), :left | :center | :right) :: any()
  def refresh(pid, id) do
    GenServer.call(pid, {:refresh, id})
  end

  # gen_server callbacks

  def init({device, handler}) do
    {:ok, uarts_pid} = Circuits.UART.start_link()
    :ok = Circuits.UART.open(uarts_pid, device.tty, speed: 256_000, active: false)
    :ok = Circuits.UART.write(uarts_pid, @ws_upgrade_header)
    {:ok, _} = Circuits.UART.read(uarts_pid)
    {:ok, handler_pid} = handler.start_link(device)

    :ok =
      Circuits.UART.configure(uarts_pid, framing: {Loupey.Framing.Websocket, []}, active: true)

    Logger.info("UARTS configuration: #{inspect(Circuits.UART.configuration(uarts_pid))}")

    {:ok,
     %State{device: device, uarts_pid: uarts_pid, handler_pid: handler_pid, handler: handler}}
  end

  def handle_call({:send, command, data}, from, state) do
    {state, transaction_id} = next_transaction_id(state, from)
    write_data(state.uarts_pid, format_message(transaction_id, command, data))
    {:noreply, state}
  end

  def handle_call({:set_brightness, value}, from, state) do
    run_command(state, from, fn _ ->
      Loupey.Device.set_brightness_command(value)
    end)
  end

  def handle_call({:set_button_color, id, color_value}, from, state) do
    run_command(state, from, fn _ ->
      Loupey.Device.set_button_color_command(id, color_value)
    end)
  end

  def handle_call({:draw_buffer, id, width, height, x, y, buffer}, from, state) do
    run_command(state, from, fn state ->
      Loupey.Device.draw_buffer_command(state.device, {id, width, height, x, y}, buffer)
    end)
  end

  def handle_call({:refresh, id}, from, state) do
    run_command(state, from, fn state ->
      Loupey.Device.refresh_command(state.device, id)
    end)
  end

  def handle_call({:fill_key, id, color}, from, state) do
    run_command(state, from, fn state ->
      Loupey.Device.fill_key_color_command(state.device, {:center, id}, color)
    end)
  end

  def handle_call({:fill_slider, id, color, percent}, from, state) do
    run_command(state, from, fn state ->
      Loupey.Device.fill_slider_color_command(state.device, id, color, percent)
    end)
  end

  def handle_call({:draw_image, button_id, image}, from, state) do
    run_command(state, from, fn state ->
      Loupey.Device.draw_image_command(state.device, button_id, image)
    end)
  end

  defp run_command(state, from, command) do
    {state, transaction_id} = next_transaction_id(state, from)
    {cmd, data} = command.(state)
    buffer = format_message(transaction_id, cmd, data)
    write_data(state.uarts_pid, buffer)
    {:noreply, state}
  end

  # Process incoming messages from the UART, we have one UART genserver per device
  # so we can safely ignore the tty field in the message.
  def handle_info({:circuits_uart, _tty, data}, state) when is_binary(data) do
    {device, message} = Loupey.Device.parse_message(state.device, data)
    state = put_in(state.device, device)
    Logger.debug("Parsed message: #{inspect(message)}")

    state =
      case message do
        {cmd, transaction_id, data}
        when is_map_key(state.pending_transactions, transaction_id) ->
          process_command_response(state, transaction_id, cmd, data)

        {:unknown_message, _} ->
          state

        _ ->
          state.handler.handle_message(message)
          state
      end

    {:noreply, state}
  end

  def handle_info(_, state) do
    {:noreply, state}
  end

  def terminate(_reason, state) do
    Circuits.UART.write(state.uarts_pid, @ws_close_frame)
    Circuits.UART.close(state.uarts_pid)
    Circuits.UART.stop(state.uarts_pid)
    {:ok, state}
  end

  defp next_transaction_id(state, from) do
    {state, transaction_id} = next_transaction_id(state)

    state =
      put_in(
        state.pending_transactions,
        Map.put(state.pending_transactions, transaction_id, from)
      )

    {state, transaction_id}
  end

  defp next_transaction_id(state) do
    transaction_id = rem(state.transaction_id + 1, 256)
    transaction_id = if transaction_id == 0, do: 1, else: transaction_id
    {put_in(state.transaction_id, transaction_id), transaction_id}
  end

  defp process_command_response(state, transaction_id, cmd, data) do
    from = Map.fetch!(state.pending_transactions, transaction_id)
    GenServer.reply(from, {cmd, data})

    put_in(
      state.pending_transactions,
      Map.delete(state.pending_transactions, transaction_id)
    )
  end

  # Websocket message framing

  defp format_message(transaction_id, command, data) when is_binary(data) do
    <<min(3 + byte_size(data), 0xFF)::8, command, transaction_id, data::binary>>
  end

  defp format_message(transaction_id, command, data) do
    <<4, command, transaction_id, data>>
  end

  # Dedicated frame handling as uarts.circuits has a limt of 16384 bytes and we need some space for
  # the header and the frame itself. Special case small payloads with a shorter header.

  defp write_data(uarts_pid, buffer) when byte_size(buffer) <= 0xFF do
    :ok = Circuits.UART.write(uarts_pid, [<<0x82, 0x80 + byte_size(buffer), 0x00::32>>, buffer])
  end

  defp write_data(uarts_pid, buffer) when byte_size(buffer) > 0xFF do
    header = <<0x82, 0xFF, 0x00::32, byte_size(buffer)::unsigned-integer-32, 0x00::32>>
    Logger.debug("Writing header: #{inspect(header)}")
    :ok = Circuits.UART.write(uarts_pid, header)
    write_data(uarts_pid, buffer, :wrote_header)
  end

  defp write_data(uarts_pid, buffer, :wrote_header) when byte_size(buffer) <= 15300 do
    Logger.debug("Writing chunk: #{inspect(buffer)}")
    :ok = Circuits.UART.write(uarts_pid, buffer)
  end

  defp write_data(uarts_pid, buffer, :wrote_header) do
    <<chunk::binary-size(15300), rest::binary>> = buffer
    Logger.debug("Writing chunk: #{inspect(chunk)}")
    :ok = Circuits.UART.write(uarts_pid, chunk)
    if byte_size(rest) > 0, do: write_data(uarts_pid, rest, :wrote_header)
  end
end
