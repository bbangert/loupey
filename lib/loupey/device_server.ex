defmodule Loupey.DeviceServer do
  @moduledoc """
  GenServer that manages a single connected device.

  Transport-agnostic. The driver owns the entire I/O stack (UART, USB-HID,
  …), all framing, and any protocol-specific state (transaction IDs,
  chunking, keep-alives). This server:

  - Asks the driver to `open/2` a connection (passing itself as `:parent`)
  - Receives `{:device_data, bytes}` messages that the driver forwards
    from its transport, calls `driver.parse/2`, and broadcasts normalized
    `Loupey.Events` via PubSub
  - Accepts `Loupey.RenderCommands`, asks the driver to `encode/1` them,
    and hands the encoded bytes back to `driver.send_command/2`
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
      :device_id
    ]
  end

  # -- Public API --

  def start_link(opts) do
    driver_module = Keyword.fetch!(opts, :driver)
    device_ref = Keyword.fetch!(opts, :device_ref)
    device_id = Keyword.get(opts, :device_id, device_ref)

    GenServer.start_link(__MODULE__, {driver_module, device_ref, device_id},
      name: via_tuple(device_id)
    )
  end

  @doc """
  Send a render command to the device.
  """
  @spec render(term(), Loupey.RenderCommands.t()) :: :ok
  def render(device_id, command) do
    GenServer.cast(via_tuple(device_id), {:render, command})
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
  def init({driver_module, device_ref, device_id}) do
    case driver_module.open(device_ref, parent: self()) do
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
    encoded = state.driver_module.encode(command)
    dispatch_send(state, encoded)
  end

  def handle_cast({:refresh, display_id}, state) do
    if function_exported?(state.driver_module, :encode_refresh, 1) do
      encoded = state.driver_module.encode_refresh(display_id)
      dispatch_send(state, encoded)
    else
      {:noreply, state}
    end
  end

  # Forward an encoded command to the driver's transport. On `{:error, reason}`
  # stop abnormally so the DynamicSupervisor restarts us (and reopens the
  # driver connection) rather than silently stranding the device.
  defp dispatch_send(state, encoded) do
    case state.driver_module.send_command(state.connection, encoded) do
      :ok ->
        {:noreply, state}

      {:error, reason} ->
        Logger.warning(
          "Driver send_command failed on #{inspect(state.device_id)}: #{inspect(reason)}"
        )

        {:stop, {:send_failed, reason}, state}
    end
  end

  @impl true
  def handle_info({:device_data, data}, state) when is_binary(data) do
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
      state.driver_module.close(state.connection)
    catch
      _, _ -> :ok
    end

    :ok
  end

  defp broadcast_event(device_id, event) do
    Phoenix.PubSub.broadcast(
      Loupey.PubSub,
      "device:#{device_id}",
      {:device_event, device_id, event}
    )
  end
end
