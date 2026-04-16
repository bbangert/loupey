defmodule Loupey.HA do
  @moduledoc """
  Public API for Home Assistant integration.

  Provides functions to connect to HA, query entity state, call services,
  and subscribe to state changes. Backed by the `hassock` library.
  """

  alias Hassock.{Config, EntityState, ServiceCall}
  alias Loupey.HA.Events

  @connection_name Loupey.HA.Connection
  @cache_name Loupey.HA.HassockCache

  @doc """
  Connect to a Home Assistant instance.

  ## Examples

      Loupey.HA.connect(%Hassock.Config{
        url: "http://homeassistant.local:8123",
        token: "your_long_lived_access_token"
      })

  """
  @spec connect(Config.t()) :: {:ok, pid()} | {:error, term()}
  def connect(%Config{} = config) do
    Loupey.HA.Supervisor.connect(config)
  end

  @doc "Disconnect from Home Assistant."
  def disconnect, do: Loupey.HA.Supervisor.disconnect()

  @doc "Check if HA is connected."
  def connected?, do: Loupey.HA.Supervisor.connected?()

  @doc """
  Call a Home Assistant service. Fire-and-forget.

  ## Examples

      Loupey.HA.call_service(%Hassock.ServiceCall{
        domain: "light",
        service: "toggle",
        target: %{entity_id: "light.living_room"}
      })

  """
  @spec call_service(ServiceCall.t()) :: :ok
  def call_service(%ServiceCall{} = call) do
    if connected?() do
      Task.Supervisor.start_child(Loupey.HA.TaskSupervisor, fn ->
        Hassock.call_service(@connection_name, call)
      end)
    end

    :ok
  end

  @doc "Get the current state of an entity, or `nil` when not connected."
  @spec get_state(String.t()) :: EntityState.t() | nil
  def get_state(entity_id) do
    if connected?(), do: Hassock.Cache.get(@cache_name, entity_id)
  end

  @doc "Get all cached entity states (empty list when not connected)."
  @spec get_all_states() :: [EntityState.t()]
  def get_all_states do
    if connected?(), do: Hassock.Cache.get_all(@cache_name), else: []
  end

  @doc "Get all entities in a domain (empty list when not connected)."
  @spec get_domain(String.t()) :: [EntityState.t()]
  def get_domain(domain) do
    if connected?(), do: Hassock.Cache.get_domain(@cache_name, domain), else: []
  end

  @doc """
  Get all available service domains and their services.
  Returns `%{"light" => ["toggle", "turn_off", "turn_on"], ...}`.
  """
  @spec get_services() :: %{String.t() => [String.t()]}
  def get_services do
    with true <- connected?(),
         {:ok, services} <- Hassock.get_services(@connection_name) do
      services
    else
      _ -> %{}
    end
  end

  @doc "Get services for a specific domain."
  @spec get_domain_services(String.t()) :: [String.t()]
  def get_domain_services(domain), do: Map.get(get_services(), domain, [])

  @doc """
  Subscribe to state changes for a specific entity.
  Events arrive as `{:ha_state_changed, entity_id, new_state, old_state}`.
  """
  defdelegate subscribe(entity_id), to: Events

  @doc "Subscribe to all entity state changes."
  defdelegate subscribe_all(), to: Events

  @doc "Subscribe to the connection-ready signal (`:ha_connected`)."
  defdelegate subscribe_connected(), to: Events
end
