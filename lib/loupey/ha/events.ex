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
  - `"ha:connected"` — `:ha_connected` after a cache's initial snapshot
    loads

  ## Reconnects

  Since hassock 0.3 the cache sends `:ready` again after every reconnect,
  once its table is back in sync (the `{:changes, ...}` for whatever moved
  during the outage arrives first and is broadcast as usual).
  `Loupey.Orchestrator` treats `:ha_connected` as "a new connection is up"
  and re-enumerates devices and re-applies the active profiles to every
  engine, so it is only broadcast for the first `:ready` of each cache
  process: a new `Loupey.HA.connect/1` (or a cache restart) starts a new
  cache and broadcasts again, a transient socket reconnect doesn't.

  `{:auth_failed, reason}` (hassock stops retrying after HA rejects the
  token) is logged as a warning.
  """

  use GenServer

  require Logger

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

  @doc "Unsubscribe from state changes for a specific entity."
  def unsubscribe(entity_id, pubsub \\ @default_pubsub) do
    Phoenix.PubSub.unsubscribe(pubsub, "ha:state:#{entity_id}")
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
  def init(pubsub), do: {:ok, %{pubsub: pubsub, ready_cache: nil}}

  @impl true
  def handle_info({:hassock_cache, cache, :ready}, %{ready_cache: cache} = state) do
    # Re-sync after a reconnect of a cache we already announced.
    {:noreply, state}
  end

  def handle_info({:hassock_cache, cache, :ready}, state) do
    Phoenix.PubSub.broadcast(state.pubsub, "ha:connected", :ha_connected)
    {:noreply, %{state | ready_cache: cache}}
  end

  def handle_info({:hassock_cache, _cache, {:auth_failed, reason}}, state) do
    # hassock stops retrying after `auth_invalid` (HA bans IPs after
    # repeated failed logins), so surface it rather than failing silently.
    Logger.warning("Home Assistant rejected the access token: #{inspect(reason)}")
    {:noreply, state}
  end

  def handle_info({:hassock_cache, _cache, {:changes, changes}}, %{pubsub: pubsub} = state) do
    %{added: added, changed: changed} = changes
    for {entity_id, new_state} <- added, do: broadcast(pubsub, entity_id, new_state, nil)

    for {entity_id, new_state, old_state} <- changed,
        do: broadcast(pubsub, entity_id, new_state, old_state)

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp broadcast(pubsub, entity_id, new_state, old_state) do
    msg = {:ha_state_changed, entity_id, new_state, old_state}
    Phoenix.PubSub.broadcast(pubsub, "ha:state:#{entity_id}", msg)
    Phoenix.PubSub.broadcast(pubsub, "ha:state:all", msg)
  end
end
