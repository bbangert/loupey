defmodule Loupey.HA.Events do
  @moduledoc """
  Thin wrapper that fans hassock cache events into `Loupey.PubSub`.

  Registered as the controlling pid for `Hassock.Cache`. Does nothing
  else: entity lookups go straight through `Hassock.Cache` (via the
  `Loupey.HA` facade), and services are fetched on demand via
  `Hassock.get_services/1`.

  ## PubSub topics

  - `"ha:state:{entity_id}"` — `{:ha_state_changed, entity_id, new, old}`
  - `"ha:state:all"` — same message for any entity
  - `"ha:connected"` — `:ha_connected` after initial snapshot loads
  """

  use GenServer

  @default_pubsub Loupey.PubSub

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    pubsub = Keyword.get(opts, :pubsub, @default_pubsub)
    GenServer.start_link(__MODULE__, pubsub, name: name)
  end

  @doc "Subscribe to state changes for a specific entity."
  def subscribe(entity_id, pubsub \\ @default_pubsub) do
    Phoenix.PubSub.subscribe(pubsub, "ha:state:#{entity_id}")
  end

  @doc "Subscribe to all state changes."
  def subscribe_all(pubsub \\ @default_pubsub) do
    Phoenix.PubSub.subscribe(pubsub, "ha:state:all")
  end

  @doc "Subscribe to the connection-ready signal."
  def subscribe_connected(pubsub \\ @default_pubsub) do
    Phoenix.PubSub.subscribe(pubsub, "ha:connected")
  end

  @impl true
  def init(pubsub), do: {:ok, pubsub}

  @impl true
  def handle_info({:hassock_cache, _cache, :ready}, pubsub) do
    Phoenix.PubSub.broadcast(pubsub, "ha:connected", :ha_connected)
    {:noreply, pubsub}
  end

  def handle_info({:hassock_cache, _cache, {:changes, changes}}, pubsub) do
    %{added: added, changed: changed} = changes
    for {entity_id, new_state} <- added, do: broadcast(pubsub, entity_id, new_state, nil)

    for {entity_id, new_state, old_state} <- changed,
        do: broadcast(pubsub, entity_id, new_state, old_state)

    {:noreply, pubsub}
  end

  def handle_info(_msg, pubsub), do: {:noreply, pubsub}

  defp broadcast(pubsub, entity_id, new_state, old_state) do
    msg = {:ha_state_changed, entity_id, new_state, old_state}
    Phoenix.PubSub.broadcast(pubsub, "ha:state:#{entity_id}", msg)
    Phoenix.PubSub.broadcast(pubsub, "ha:state:all", msg)
  end
end
