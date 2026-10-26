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
  - `"ha:status"` — `{:ha_ready, ready?}` whenever `ready?/1` changes,
    including when the same cache re-syncs after a reconnect (for UI
    status; unlike `"ha:connected"` it isn't deduped)
  - `"ha:auth_failed"` — `{:ha_auth_failed, reason}` when HA rejects the
    token (hassock then stops retrying)

  `ready?/1` says whether the cache is currently in sync with HA, as
  opposed to `Loupey.HA.connected?/0`, which only says the connection
  process is running (since hassock 0.3 it connects and authenticates in
  the background, so a running process may never get to `:ready`).

  ## Reconnects

  Since hassock 0.3 the cache sends `:ready` again after every reconnect,
  once its table is back in sync (the `{:changes, ...}` for whatever moved
  during the outage arrives first and is broadcast as usual).
  `Loupey.Orchestrator` treats `:ha_connected` as "a new connection is up"
  and re-enumerates devices and re-applies the active profiles to every
  engine, so it is only broadcast for the first `:ready` of each cache
  process: a new `Loupey.HA.connect/1` (or a cache restart) starts a new
  cache and broadcasts again, a transient socket reconnect doesn't.

  `{:auth_failed, reason}` is also logged as a warning.
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

  @doc "Subscribe to `{:ha_ready, ready?}` readiness transitions."
  def subscribe_status(pubsub \\ @default_pubsub) do
    Phoenix.PubSub.subscribe(pubsub, "ha:status")
  end

  @doc "Subscribe to `{:ha_auth_failed, reason}` (HA rejected the token)."
  def subscribe_auth_failed(pubsub \\ @default_pubsub) do
    Phoenix.PubSub.subscribe(pubsub, "ha:auth_failed")
  end

  @doc """
  Whether a hassock cache is currently in sync with Home Assistant: it has
  sent `:ready` and hasn't since reported a disconnect or an auth failure.
  `false` when this process isn't running.
  """
  @spec ready?(GenServer.server()) :: boolean()
  def ready?(server \\ __MODULE__) do
    GenServer.call(server, :ready?)
  catch
    :exit, _ -> false
  end

  # `announced` is the last cache whose `:ready` was broadcast (dedupes the
  # re-sync `:ready` after a reconnect); `ready` is the cache that is in
  # sync right now, or nil.
  @impl true
  def init(pubsub), do: {:ok, %{pubsub: pubsub, announced: nil, ready: nil, monitor: nil}}

  @impl true
  def handle_call(:ready?, _from, %{ready: ready} = state) do
    {:reply, is_pid(ready) and Process.alive?(ready), state}
  end

  @impl true
  def handle_info({:hassock_cache, cache, :ready}, %{announced: cache} = state) do
    # Re-sync after a reconnect of a cache we already announced: only the
    # status topic hears about it.
    {:noreply, set_ready(state, cache)}
  end

  def handle_info({:hassock_cache, cache, :ready}, state) do
    # Watch the cache so a crash or `HA.disconnect/0` (neither sends
    # `:disconnected`) still flips the status to not ready.
    if state.monitor, do: Process.demonitor(state.monitor, [:flush])
    monitor = Process.monitor(cache)

    state = set_ready(state, cache)
    Phoenix.PubSub.broadcast(state.pubsub, "ha:connected", :ha_connected)
    {:noreply, %{state | announced: cache, monitor: monitor}}
  end

  def handle_info({:DOWN, ref, :process, cache, _reason}, %{monitor: ref} = state) do
    state = if state.ready == cache, do: set_ready(state, nil), else: state
    {:noreply, %{state | monitor: nil}}
  end

  def handle_info({:hassock_cache, _cache, :disconnected}, state) do
    {:noreply, set_ready(state, nil)}
  end

  def handle_info({:hassock_cache, _cache, {:auth_failed, reason}}, state) do
    # hassock stops retrying after `auth_invalid` (HA bans IPs after
    # repeated failed logins), so surface it rather than failing silently.
    Logger.warning("Home Assistant rejected the access token: #{inspect(reason)}")
    Phoenix.PubSub.broadcast(state.pubsub, "ha:auth_failed", {:ha_auth_failed, reason})
    {:noreply, set_ready(state, nil)}
  end

  def handle_info({:hassock_cache, _cache, {:changes, changes}}, %{pubsub: pubsub} = state) do
    %{added: added, changed: changed} = changes
    for {entity_id, new_state} <- added, do: broadcast(pubsub, entity_id, new_state, nil)

    for {entity_id, new_state, old_state} <- changed,
        do: broadcast(pubsub, entity_id, new_state, old_state)

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp set_ready(%{ready: ready} = state, ready), do: state

  defp set_ready(state, ready) do
    if is_nil(state.ready) != is_nil(ready) do
      Phoenix.PubSub.broadcast(state.pubsub, "ha:status", {:ha_ready, ready != nil})
    end

    %{state | ready: ready}
  end

  defp broadcast(pubsub, entity_id, new_state, old_state) do
    msg = {:ha_state_changed, entity_id, new_state, old_state}
    Phoenix.PubSub.broadcast(pubsub, "ha:state:#{entity_id}", msg)
    Phoenix.PubSub.broadcast(pubsub, "ha:state:all", msg)
  end
end
