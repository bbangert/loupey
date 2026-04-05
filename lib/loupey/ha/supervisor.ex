defmodule Loupey.HA.Supervisor do
  @moduledoc """
  Supervises the Home Assistant connection and state cache.

  Started by `Loupey.HA.connect/1` when the user provides HA configuration.
  Not started automatically — HA connection is opt-in.
  """

  use Supervisor

  alias Loupey.HA.{Config, Connection, StateCache}

  def start_link(%Config{} = config) do
    Supervisor.start_link(__MODULE__, config, name: __MODULE__)
  end

  @impl true
  def init(%Config{} = config) do
    children = [
      {StateCache, []},
      %{
        id: Connection,
        start:
          {Connection, :start_link,
           [
             [
               config: config,
               on_event: StateCache.event_callback(),
               name: Loupey.HA.Connection
             ]
           ]}
      }
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
