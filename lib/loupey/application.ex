defmodule Loupey.Application do
  @moduledoc """
  Top-level application supervisor.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # PubSub for all event dispatch (replaces EventRegistry and HAEventRegistry)
      {Phoenix.PubSub, name: Loupey.PubSub},
      # Database
      Loupey.Repo,
      # Telemetry
      LoupeyWeb.Telemetry,
      # Registry for looking up DeviceServer processes by device_id
      {Registry, keys: :unique, name: Loupey.DeviceRegistry},
      # DynamicSupervisor for device connections
      {DynamicSupervisor, name: Loupey.DeviceSupervisor, strategy: :one_for_one},
      # Phoenix endpoint
      LoupeyWeb.Endpoint
    ]

    result = Supervisor.start_link(children, strategy: :one_for_one, name: Loupey.Supervisor)

    # Auto-connect to HA if there's a saved config
    with {:ok, _} <- result do
      auto_connect_ha()
    end

    result
  end

  defp auto_connect_ha do
    case Loupey.Settings.get_active_ha_config() do
      %{url: url, token: token} ->
        Loupey.HA.connect(%Loupey.HA.Config{url: url, token: token})

      nil ->
        :ok
    end
  rescue
    _ -> :ok
  end

  @impl true
  def config_change(changed, _new, removed) do
    LoupeyWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
