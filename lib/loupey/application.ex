defmodule Loupey.Application do
  @moduledoc """
  Top-level application supervisor.

  Starts the registries needed for device management and event dispatch.
  Device connections are started dynamically via `Loupey.DeviceSupervisor`.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Registry for looking up DeviceServer processes by device_id
      {Registry, keys: :unique, name: Loupey.DeviceRegistry},
      # Registry for pub/sub event dispatch (duplicate keys — multiple subscribers per device)
      {Registry, keys: :duplicate, name: Loupey.EventRegistry},
      # Registry for HA state change pub/sub (duplicate keys — multiple subscribers per entity)
      {Registry, keys: :duplicate, name: Loupey.HAEventRegistry},
      # DynamicSupervisor for device connections
      {DynamicSupervisor, name: Loupey.DeviceSupervisor, strategy: :one_for_one}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Loupey.Supervisor)
  end
end
