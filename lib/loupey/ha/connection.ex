defmodule Loupey.HA.Connection do
  @moduledoc """
  WebSocket client for Home Assistant.

  Thin process boundary that manages the WebSocket connection, authentication
  handshake, and event subscriptions. All message parsing/encoding is delegated
  to `Loupey.HA.Messages`.

  ## Lifecycle

  1. Connects to HA WebSocket endpoint
  2. Receives `auth_required`, sends access token
  3. On `auth_ok`, fetches all current states and subscribes to `state_changed`
  4. Forwards parsed events to the `HAStateCache` via the configured callback

  On disconnect, WebSockex handles reconnection automatically.
  """

  use WebSockex
  require Logger

  alias Loupey.HA.{Config, Messages, ServiceCall}

  defmodule State do
    @moduledoc false
    defstruct [
      :config,
      :on_event,
      next_id: 1,
      pending: %{},
      authenticated: false,
      subscribe_id: nil,
      get_states_id: nil
    ]
  end

  # -- Public API --

  @doc """
  Start the WebSocket connection to Home Assistant.

  Options:
  - `:config` — `%Loupey.HA.Config{}` (required)
  - `:on_event` — callback function `(parsed_message -> :ok)` for dispatching
    events to the state cache (required)
  - `:name` — process name (optional)
  """
  def start_link(opts) do
    config = Keyword.fetch!(opts, :config)
    on_event = Keyword.fetch!(opts, :on_event)
    name = Keyword.get(opts, :name)

    url = Config.websocket_url(config)

    state = %State{
      config: config,
      on_event: on_event
    }

    ws_opts = if name, do: [name: name], else: []

    WebSockex.start_link(url, __MODULE__, state, ws_opts)
  end

  @doc """
  Call a Home Assistant service through the WebSocket connection.
  """
  @spec call_service(pid() | atom(), ServiceCall.t()) :: :ok
  def call_service(pid, %ServiceCall{} = service_call) do
    WebSockex.cast(pid, {:call_service, service_call})
  end

  # -- WebSockex callbacks --

  @impl true
  def handle_frame({:text, json}, state) do
    message = Messages.parse(json)

    case message do
      :auth_required ->
        Logger.info("HA: auth required, sending token")
        frame = {:text, Messages.encode_auth(state.config.token)}
        {:reply, frame, state}

      :auth_ok ->
        Logger.info("HA: authenticated")
        state = %{state | authenticated: true}
        # Fetch all current states, then subscribe to changes
        {state, get_states_frame} = send_msg(state, &Messages.encode_get_states/1)
        state = %{state | get_states_id: state.next_id - 1}
        {:reply, get_states_frame, state}

      {:auth_invalid, reason} ->
        Logger.error("HA: auth failed: #{reason}")
        {:close, state}

      {:states, id, entity_states} when id == state.get_states_id ->
        Logger.info("HA: received #{length(entity_states)} entity states")
        dispatch(state, {:initial_states, entity_states})

        # Now subscribe to state_changed events
        {state, sub_frame} = send_msg(state, &Messages.encode_subscribe/1)
        state = %{state | subscribe_id: state.next_id - 1}
        {:reply, sub_frame, state}

      {:state_changed, _id, new_state, old_state} ->
        dispatch(state, {:state_changed, new_state, old_state})
        {:ok, state}

      {:result, id, success, _result} ->
        if not success do
          Logger.warning("HA: command #{id} failed")
        end

        {callback, pending} = Map.pop(state.pending, id)
        if callback, do: callback.({success, id})
        {:ok, %{state | pending: pending}}

      {:event, _id, type, _event} ->
        Logger.debug("HA: unhandled event type: #{type}")
        {:ok, state}

      {:unknown, msg} ->
        Logger.debug("HA: unknown message: #{inspect(msg)}")
        {:ok, state}
    end
  end

  def handle_frame(_frame, state) do
    {:ok, state}
  end

  @impl true
  def handle_cast({:call_service, service_call}, state) do
    {state, frame} = send_msg(state, &Messages.encode_service_call(&1, service_call))
    {:reply, frame, state}
  end

  @impl true
  def handle_disconnect(%{reason: reason}, state) do
    Logger.warning("HA: disconnected: #{inspect(reason)}, reconnecting...")
    {:reconnect, %{state | authenticated: false, subscribe_id: nil, get_states_id: nil}}
  end

  # -- Internals --

  defp send_msg(state, encode_fn) do
    id = state.next_id
    json = encode_fn.(id)
    state = %{state | next_id: id + 1}
    {state, {:text, json}}
  end

  defp dispatch(%State{on_event: on_event}, event) when is_function(on_event, 1) do
    on_event.(event)
  end
end
