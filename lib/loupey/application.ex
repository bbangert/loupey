defmodule Loupey.Application do
  @moduledoc """
  Top-level application supervisor.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: Loupey.PubSub},
      Loupey.Repo,
      LoupeyWeb.Telemetry,
      {Registry, keys: :unique, name: Loupey.DeviceRegistry},
      Loupey.HA.Supervisor,
      {DynamicSupervisor, name: Loupey.DeviceSupervisor, strategy: :one_for_one},
      Loupey.Orchestrator,
      LoupeyWeb.Endpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Loupey.Supervisor)
  end

  @impl true
  def config_change(changed, _new, removed) do
    LoupeyWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
