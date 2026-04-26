defmodule Loupey.Animation do
  @moduledoc """
  Top-level supervisor for the animation system.

  Owns one `Loupey.Animation.Ticker` per active device. The Orchestrator
  starts a Ticker alongside each Engine when a device connects, and
  terminates it on device removal. Same lifecycle pattern as
  `Loupey.Bindings.Engine`.
  """

  use DynamicSupervisor

  alias Loupey.Animation.Ticker

  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Start a Ticker for a device. Idempotent — if a Ticker is already
  running for this `device_id`, returns `{:ok, pid}` of the existing
  one without restarting it.
  """
  @spec start_ticker(keyword()) :: DynamicSupervisor.on_start_child()
  def start_ticker(opts) do
    spec = %{
      id: {:ticker, Keyword.fetch!(opts, :device_id)},
      start: {Ticker, :start_link, [opts]},
      restart: :transient
    }

    case DynamicSupervisor.start_child(__MODULE__, spec) do
      {:error, {:already_started, pid}} -> {:ok, pid}
      other -> other
    end
  end

  @doc """
  Stop the Ticker for a device. Returns `:ok` whether or not one was
  running.
  """
  @spec stop_ticker(term()) :: :ok
  def stop_ticker(device_id) do
    case Registry.lookup(Loupey.DeviceRegistry, {:ticker, device_id}) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(__MODULE__, pid)
      [] -> :ok
    end

    :ok
  end
end
