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
      {Task.Supervisor, name: Loupey.HA.TaskSupervisor},
      Loupey.HA.Supervisor,
      {DynamicSupervisor, name: Loupey.DeviceSupervisor, strategy: :one_for_one},
      Loupey.Orchestrator,
      LoupeyWeb.Endpoint
    ]

    # `:rest_for_one` — when a child crashes, everything after it in the
    # list restarts too. Matches the actual dependency graph: e.g. if
    # `DeviceSupervisor` dies, Orchestrator's internal state about which
    # engines are running goes stale, so restarting it keeps the
    # supervision tree coherent. The `DynamicSupervisor` child specs are
    # declared with `:transient` restart (see engine-transient-restart
    # plan) so individual engines still stop cleanly on deactivate.
    Supervisor.start_link(children, strategy: :rest_for_one, name: Loupey.Supervisor)
  end

  @impl true
  def config_change(changed, _new, removed) do
    LoupeyWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
