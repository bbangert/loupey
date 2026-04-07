defmodule Loupey.HA.Supervisor do
  @moduledoc """
  Supervises the Home Assistant connection and state cache.

  Starts as a proper child of the Application supervisor. Always runs
  the StateCache (so entity lookups never crash). The Connection is
  started dynamically when `connect/1` is called with HA config.

  Uses `rest_for_one` — if StateCache crashes, Connection restarts too.
  """

  use Supervisor

  alias Loupey.HA.{Config, Connection, StateCache}

  def start_link(_opts) do
    Supervisor.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc """
  Start the HA WebSocket connection with the given config.
  If already connected, returns `{:error, :already_started}`.
  """
  def connect(%Config{} = config) do
    child_spec = %{
      id: Connection,
      start:
        {Connection, :start_link,
         [
           [
             config: config,
             on_event: StateCache.event_callback(),
             name: Loupey.HA.Connection
           ]
         ]},
      restart: :permanent
    }

    Supervisor.start_child(__MODULE__, child_spec)
  end

  @doc """
  Stop the HA WebSocket connection.
  """
  def disconnect do
    case Supervisor.terminate_child(__MODULE__, Connection) do
      :ok -> Supervisor.delete_child(__MODULE__, Connection)
      error -> error
    end
  end

  @doc """
  Check if the HA connection is running.
  """
  def connected? do
    Process.whereis(Loupey.HA.Connection) != nil
  end

  @impl true
  def init(:ok) do
    children = [
      {StateCache, []}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
