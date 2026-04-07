defmodule Loupey.Orchestrator do
  @moduledoc """
  GenServer that manages the lifecycle of device connections and binding engines.

  Serializes all mutations (activate/deactivate/reload/connect) to prevent
  race conditions. Subscribes to PubSub for HA connection events to trigger
  device connection when HA is ready (replacing the old sleep-based approach).

  Holds minimal state — the source of truth is always the database. State
  tracks which devices are connected and whether HA is ready, to coordinate
  startup sequencing.
  """

  use GenServer
  require Logger

  alias Loupey.Bindings.Engine
  alias Loupey.Devices
  alias Loupey.DeviceServer
  alias Loupey.Profiles

  defmodule State do
    @moduledoc false
    defstruct ha_ready: false
  end

  # -- Public API --

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Discover and connect all available devices.
  If there's an active profile and HA is ready, start binding engines.
  """
  def connect_all_devices do
    GenServer.call(__MODULE__, :connect_all_devices, 15_000)
  end

  @doc """
  Activate a profile: mark it active in the DB, start binding engines
  on all connected devices that match the profile's device type.
  """
  def activate_profile(profile_id) do
    GenServer.call(__MODULE__, {:activate_profile, profile_id}, 15_000)
  end

  @doc """
  Deactivate a profile: stop any running binding engines, mark inactive.
  """
  def deactivate_profile(profile_id) do
    GenServer.call(__MODULE__, {:deactivate_profile, profile_id}, 15_000)
  end

  @doc """
  Reload the active profile on all running engines.
  Called after editing bindings/layouts in the UI.
  """
  def reload_active_profile do
    GenServer.cast(__MODULE__, :reload_active_profile)
  end

  @doc """
  Get the status of all connected devices and their engines.
  """
  def status do
    GenServer.call(__MODULE__, :status)
  end

  # -- GenServer callbacks --

  @impl true
  def init(_opts) do
    # Subscribe to HA connection events
    Phoenix.PubSub.subscribe(Loupey.PubSub, "ha:connected")

    # Auto-connect HA from saved config
    auto_connect_ha()

    {:ok, %State{}}
  end

  @impl true
  def handle_call(:connect_all_devices, _from, state) do
    results = do_connect_all_devices()
    {:reply, results, state}
  end

  def handle_call({:activate_profile, profile_id}, _from, state) do
    result = do_activate_profile(profile_id)
    {:reply, result, state}
  end

  def handle_call({:deactivate_profile, profile_id}, _from, state) do
    result = do_deactivate_profile(profile_id)
    {:reply, result, state}
  end

  def handle_call(:status, _from, state) do
    {:reply, build_status(), state}
  end

  @impl true
  def handle_cast(:reload_active_profile, state) do
    do_reload_active_profile()
    {:noreply, state}
  end

  @impl true
  def handle_info(:ha_connected, state) do
    Logger.info("Orchestrator: HA connected, connecting devices")
    do_connect_all_devices()
    {:noreply, %{state | ha_ready: true}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- Internal: Device Connection --

  defp do_connect_all_devices do
    results = Devices.connect_all()

    case Profiles.get_active_profile() do
      nil ->
        Logger.info("Orchestrator: devices connected, no active profile")

      profile ->
        activate_profile_on_devices(profile)
    end

    results
  end

  # -- Internal: Profile Lifecycle --

  defp do_activate_profile(profile_id) do
    # Deactivate all profiles first
    for p <- Profiles.list_profiles(), p.active do
      do_deactivate_profile(p.id)
    end

    profile = Profiles.get_profile(profile_id)

    if profile do
      Profiles.update_profile(profile, %{"active" => true})
      profile = Profiles.get_profile(profile_id)
      activate_profile_on_devices(profile)
      {:ok, profile}
    else
      {:error, :not_found}
    end
  end

  defp do_deactivate_profile(profile_id) do
    profile = Profiles.get_profile(profile_id)

    if profile do
      stop_all_engines()
      Profiles.update_profile(profile, %{"active" => false})
      :ok
    else
      {:error, :not_found}
    end
  end

  defp do_reload_active_profile do
    case Profiles.get_active_profile() do
      nil -> :ok
      profile -> activate_profile_on_devices(profile)
    end
  end

  defp activate_profile_on_devices(profile) do
    core_profile = Profiles.to_core_profile(profile)

    for {_driver, tty} <- Devices.discover() do
      ensure_connected(tty)
      maybe_start_engine(tty, core_profile, profile.device_type)
    end
  end

  defp maybe_start_engine(device_id, core_profile, expected_type) do
    case safe_get_spec(device_id) do
      %{type: ^expected_type} -> start_or_update_engine(device_id, core_profile)
      _ -> :ok
    end
  end

  # -- Internal: Engine Management --

  defp start_or_update_engine(device_id, core_profile) do
    if engine_running?(device_id) do
      Engine.update_profile(device_id, core_profile)
      Logger.info("Orchestrator: updated engine on #{device_id}")
    else
      child_spec = %{
        id: {:engine, device_id},
        start: {Engine, :start_link, [[device_id: device_id, profile: core_profile]]},
        restart: :permanent
      }

      case DynamicSupervisor.start_child(Loupey.DeviceSupervisor, child_spec) do
        {:ok, _pid} ->
          Logger.info("Orchestrator: started engine on #{device_id}")

        {:error, {:already_started, _}} ->
          Engine.update_profile(device_id, core_profile)

        {:error, reason} ->
          Logger.error("Orchestrator: failed to start engine on #{device_id}: #{inspect(reason)}")
      end
    end
  end

  defp stop_all_engines do
    for {_driver, tty} <- Devices.discover() do
      stop_engine(tty)
    end
  end

  defp stop_engine(device_id) do
    case Registry.lookup(Loupey.DeviceRegistry, {:engine, device_id}) do
      [{pid, _}] ->
        DynamicSupervisor.terminate_child(Loupey.DeviceSupervisor, pid)
        Logger.info("Orchestrator: stopped engine on #{device_id}")

      [] ->
        :ok
    end
  end

  defp engine_running?(device_id) do
    Registry.lookup(Loupey.DeviceRegistry, {:engine, device_id}) != []
  end

  # -- Internal: Helpers --

  defp ensure_connected(device_id) do
    case Registry.lookup(Loupey.DeviceRegistry, device_id) do
      [{_pid, _}] -> :ok
      [] -> connect_by_id(device_id)
    end
  end

  defp connect_by_id(device_id) do
    case Enum.find(Devices.discover(), fn {_d, tty} -> tty == device_id end) do
      {driver, tty} -> Devices.connect(driver, tty)
      nil -> :ok
    end
  end

  defp safe_get_spec(device_id) do
    DeviceServer.get_spec(device_id)
  rescue
    error ->
      Logger.debug("Failed to get spec for #{device_id}: #{inspect(error)}")
      nil
  catch
    :exit, reason ->
      Logger.debug("Process exit getting spec for #{device_id}: #{inspect(reason)}")
      nil
  end

  defp build_status do
    connected_devices =
      Devices.discover()
      |> Enum.map(fn {driver, tty} ->
        spec = safe_get_spec(tty)

        %{
          tty: tty,
          device_id: tty,
          driver: driver,
          connected: spec != nil,
          device_type: spec && spec.type,
          engine_running: engine_running?(tty)
        }
      end)

    active_profile = Profiles.get_active_profile()

    %{
      devices: connected_devices,
      active_profile: active_profile && %{id: active_profile.id, name: active_profile.name}
    }
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
end
