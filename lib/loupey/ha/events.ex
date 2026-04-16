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

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc "Subscribe to state changes for a specific entity."
  def subscribe(entity_id) do
    Phoenix.PubSub.subscribe(Loupey.PubSub, "ha:state:#{entity_id}")
  end

  @doc "Subscribe to all state changes."
  def subscribe_all do
    Phoenix.PubSub.subscribe(Loupey.PubSub, "ha:state:all")
  end

  @doc "Subscribe to the connection-ready signal."
  def subscribe_connected do
    Phoenix.PubSub.subscribe(Loupey.PubSub, "ha:connected")
  end

  @impl true
  def init(:ok), do: {:ok, nil}

  @impl true
  def handle_info({:hassock_cache, _cache, :ready}, state) do
    Phoenix.PubSub.broadcast(Loupey.PubSub, "ha:connected", :ha_connected)
    {:noreply, state}
  end

  def handle_info({:hassock_cache, _cache, {:changes, changes}}, state) do
    %{added: added, changed: changed} = changes
    for {entity_id, new_state} <- added, do: broadcast(entity_id, new_state, nil)
    for {entity_id, new_state, old_state} <- changed, do: broadcast(entity_id, new_state, old_state)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp broadcast(entity_id, new_state, old_state) do
    msg = {:ha_state_changed, entity_id, new_state, old_state}
    Phoenix.PubSub.broadcast(Loupey.PubSub, "ha:state:#{entity_id}", msg)
    Phoenix.PubSub.broadcast(Loupey.PubSub, "ha:state:all", msg)
  end
end
