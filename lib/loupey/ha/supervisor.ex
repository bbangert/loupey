defmodule Loupey.HA.Supervisor do
  @moduledoc """
  Supervises the Home Assistant integration.

  `Events` runs as a permanent child so PubSub subscribe helpers work
  before a connection exists. `Hassock.Supervisor` is started dynamically
  by `connect/1` with `Events`'s pid as the event controller.

  Uses `rest_for_one` — if `Events` crashes, the hassock tree restarts
  too, so the fresh `Events` pid re-owns cache events.
  """

  use Supervisor

  alias Loupey.HA.Events

  @hassock_sup Loupey.HA.HassockSupervisor
  @connection_name Loupey.HA.Connection
  @cache_name Loupey.HA.HassockCache

  def start_link(_opts) do
    Supervisor.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc """
  Start the hassock connection + cache with the given config.
  If already connected, returns `{:error, :already_started}`.
  """
  def connect(%Hassock.Config{} = config) do
    child_spec = %{
      id: :hassock,
      start:
        {Hassock.Supervisor, :start_link,
         [
           [
             config: config,
             cache: true,
             controller: Events,
             name: @hassock_sup,
             connection_name: @connection_name,
             cache_name: @cache_name
           ]
         ]},
      restart: :permanent
    }

    Supervisor.start_child(__MODULE__, child_spec)
  end

  @doc "Stop the hassock connection."
  def disconnect do
    case Supervisor.terminate_child(__MODULE__, :hassock) do
      :ok -> Supervisor.delete_child(__MODULE__, :hassock)
      error -> error
    end
  end

  @doc "Check if the HA connection is running."
  def connected? do
    Process.whereis(@connection_name) != nil
  end

  @impl true
  def init(:ok) do
    Supervisor.init([Events], strategy: :rest_for_one)
  end
end
