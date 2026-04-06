defmodule Loupey.HA.StateCache do
  @moduledoc """
  ETS-backed cache of Home Assistant entity states with event broadcasting.

  Receives state updates from `HAConnection`, stores them in ETS for fast
  lookup, and broadcasts meaningful changes via Registry so the binding
  engine can react.

  ## PubSub Topics (via Loupey.PubSub / Phoenix.PubSub)

  - `"ha:state:{entity_id}"` — state changed for a specific entity
  - `"ha:state:all"` — any entity state changed
  - `"ha:connected"` — initial state load complete (HA is ready)
  """

  use GenServer
  require Logger

  alias Loupey.HA.{EntityState, Messages}

  @table __MODULE__

  # -- Public API --

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Get the current state of an entity. Returns `nil` if not found.
  """
  @spec get(String.t()) :: EntityState.t() | nil
  def get(entity_id) do
    case :ets.lookup(@table, entity_id) do
      [{^entity_id, state}] -> state
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc """
  Get all cached entity states.
  """
  @spec get_all() :: [EntityState.t()]
  def get_all do
    :ets.tab2list(@table)
    |> Enum.map(fn {_id, state} -> state end)
  rescue
    ArgumentError -> []
  end

  @doc """
  Get all entity IDs matching a domain (e.g., "light", "media_player").
  """
  @spec get_by_domain(String.t()) :: [EntityState.t()]
  def get_by_domain(domain) do
    prefix = domain <> "."

    get_all()
    |> Enum.filter(&String.starts_with?(&1.entity_id, prefix))
  end

  @doc """
  Subscribe the calling process to state changes for a specific entity.
  Events arrive as `{:ha_state_changed, entity_id, new_state, old_state}`.
  """
  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(entity_id) do
    Phoenix.PubSub.subscribe(Loupey.PubSub, "ha:state:#{entity_id}")
  end

  @doc """
  Subscribe the calling process to all state changes.
  """
  @spec subscribe_all() :: :ok | {:error, term()}
  def subscribe_all do
    Phoenix.PubSub.subscribe(Loupey.PubSub, "ha:state:all")
  end

  @doc """
  Subscribe to the connection-ready signal.
  Fires once after initial state load.
  """
  @spec subscribe_connected() :: :ok | {:error, term()}
  def subscribe_connected do
    Phoenix.PubSub.subscribe(Loupey.PubSub, "ha:connected")
  end

  @doc """
  The callback function to pass to `HAConnection` as `:on_event`.
  Routes connection events into this GenServer.
  """
  @spec event_callback() :: (term() -> :ok)
  def event_callback do
    fn event ->
      GenServer.cast(__MODULE__, {:ha_event, event})
      :ok
    end
  end

  # -- GenServer callbacks --

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{table: table}}
  end

  @impl true
  def handle_cast({:ha_event, {:initial_states, states}}, state) do
    for %EntityState{} = entity_state <- states do
      :ets.insert(@table, {entity_state.entity_id, entity_state})
    end

    Logger.info("HA StateCache: loaded #{length(states)} entities")

    broadcast("ha:connected", :ha_connected)

    {:noreply, state}
  end

  def handle_cast({:ha_event, {:state_changed, new_state, old_state}}, state) do
    old_cached = get(new_state.entity_id)
    old = old_state || old_cached

    if Messages.state_changed?(old, new_state) do
      :ets.insert(@table, {new_state.entity_id, new_state})

      msg = {:ha_state_changed, new_state.entity_id, new_state, old}
      broadcast("ha:state:#{new_state.entity_id}", msg)
      broadcast("ha:state:all", msg)
    end

    {:noreply, state}
  end

  def handle_cast({:ha_event, _other}, state) do
    {:noreply, state}
  end

  # -- Internals --

  defp broadcast(topic, message) do
    Phoenix.PubSub.broadcast(Loupey.PubSub, topic, message)
  end
end
