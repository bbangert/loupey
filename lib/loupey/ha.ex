defmodule Loupey.HA do
  @moduledoc """
  Public API for Home Assistant integration.

  Provides functions to connect to HA, query entity state, call services,
  and subscribe to state changes.
  """

  alias Loupey.HA.{Config, Connection, ServiceCall, StateCache}

  @doc """
  Connect to a Home Assistant instance.

  Starts the HA supervisor which manages the WebSocket connection and state cache.
  The connection authenticates, fetches all current states, and subscribes to changes.

  ## Examples

      Loupey.HA.connect(%Loupey.HA.Config{
        url: "http://homeassistant.local:8123",
        token: "your_long_lived_access_token"
      })

  """
  @spec connect(Config.t()) :: {:ok, pid()} | {:error, term()}
  def connect(%Config{} = config) do
    Loupey.HA.Supervisor.start_link(config)
  end

  @doc """
  Call a Home Assistant service.

  ## Examples

      Loupey.HA.call_service(%Loupey.HA.ServiceCall{
        domain: "light",
        service: "toggle",
        target: %{entity_id: "light.living_room"}
      })

  """
  @spec call_service(ServiceCall.t()) :: :ok
  def call_service(%ServiceCall{} = call) do
    Connection.call_service(Loupey.HA.Connection, call)
  end

  @doc """
  Get the current state of an entity.
  """
  @spec get_state(String.t()) :: Loupey.HA.EntityState.t() | nil
  def get_state(entity_id) do
    StateCache.get(entity_id)
  end

  @doc """
  Get all cached entity states.
  """
  @spec get_all_states() :: [Loupey.HA.EntityState.t()]
  def get_all_states do
    StateCache.get_all()
  end

  @doc """
  Get all entities in a domain (e.g., "light", "switch", "media_player").
  """
  @spec get_domain(String.t()) :: [Loupey.HA.EntityState.t()]
  def get_domain(domain) do
    StateCache.get_by_domain(domain)
  end

  @doc """
  Subscribe to state changes for a specific entity.
  Events arrive as `{:ha_state_changed, entity_id, new_state, old_state}`.
  """
  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(entity_id) do
    StateCache.subscribe(entity_id)
  end

  @doc """
  Subscribe to all entity state changes.
  """
  @spec subscribe_all() :: :ok | {:error, term()}
  def subscribe_all do
    StateCache.subscribe_all()
  end
end
