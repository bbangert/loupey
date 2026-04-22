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
  alias Loupey.Repo

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
    GenServer.call(__MODULE__, :status, 5_000)
  end

  # -- GenServer callbacks --

  @impl true
  def init(_opts) do
    # Subscribe to HA connection events
    Phoenix.PubSub.subscribe(Loupey.PubSub, "ha:connected")

    # Defer HA auto-connect off the init path so supervisor startup stays
    # non-blocking (`HA.connect/1` can hang on a slow network / unreachable
    # host). By the time this message is handled, init has returned and
    # subsequent children in the supervision tree have already started.
    send(self(), :auto_connect_ha)

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
  def handle_info(:auto_connect_ha, state) do
    auto_connect_ha()
    {:noreply, state}
  end

  def handle_info(:ha_connected, state) do
    Logger.info("Orchestrator: HA connected, connecting devices")
    do_connect_all_devices()
    {:noreply, %{state | ha_ready: true}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- Internal: Device Connection --

  defp do_connect_all_devices do
    # Refresh the cached device list — this is the single path that actually
    # hits hidraw/UART enumeration. Every other caller (`activate_profile`,
    # `status`, `stop_engines_for`, …) reads from the cache so a busy UI
    # doesn't re-enumerate on every call.
    refresh_discovered()

    results = Devices.connect_all()

    case Profiles.list_active_profiles() do
      [] ->
        Logger.info("Orchestrator: devices connected, no active profiles")

      profiles ->
        for profile <- profiles, do: activate_profile_on_devices(profile)
    end

    results
  end

  # -- Internal: Profile Lifecycle --

  defp do_activate_profile(profile_id) do
    case Profiles.get_profile(profile_id) do
      nil ->
        {:error, :not_found}

      profile ->
        # Atomic swap at the DB level — deactivate other profiles for the
        # same device_type, activate the target, all in one transaction.
        # Engines on the affected devices don't need an explicit stop:
        # `start_or_update_engine/2` updates the existing engine in place
        # if one is already running.
        case Profiles.activate_exclusive(profile) do
          {:ok, updated} ->
            # Preload layouts+bindings onto the already-loaded struct rather
            # than issuing a second `get_profile/1` fetch. `Repo.preload/2`
            # is a no-op for associations already loaded on the input.
            profile = Repo.preload(updated, layouts: [bindings: []])
            activate_profile_on_devices(profile)
            {:ok, profile}

          {:error, reason} ->
            Logger.error(
              "Orchestrator: activate_exclusive failed for profile #{profile_id}: #{inspect(reason)}"
            )

            {:error, reason}
        end
    end
  end

  defp do_deactivate_profile(profile_id) do
    case Profiles.get_profile(profile_id) do
      nil ->
        {:error, :not_found}

      profile ->
        # Update DB first, stop engines only on success. The previous order
        # could leave the DB marked `active: true` while engines were
        # already torn down if the update failed — worse than the inverse.
        case Profiles.deactivate(profile) do
          {:ok, _} ->
            stop_engines_for(profile.device_type)
            :ok

          {:error, _} = err ->
            err
        end
    end
  end

  defp do_reload_active_profile do
    for profile <- Profiles.list_active_profiles() do
      activate_profile_on_devices(profile)
    end

    :ok
  end

  defp activate_profile_on_devices(profile) do
    core_profile = Profiles.to_core_profile(profile)

    for {_driver, device_ref} <- discovered_devices() do
      ensure_connected(device_ref)
      maybe_start_engine(device_ref, core_profile, profile.device_type)
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
        restart: :transient
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

  # Stop engines only for devices of the given device type — leaves engines
  # for other device types running so a multi-device setup isn't torn down
  # when deactivating a single profile.
  defp stop_engines_for(device_type) do
    for {_driver, device_ref} <- discovered_devices(),
        spec = safe_get_spec(device_ref),
        spec != nil,
        spec.type == device_type do
      stop_engine(device_ref)
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
    case Enum.find(discovered_devices(), fn {_d, device_ref} -> device_ref == device_id end) do
      {driver, device_ref} -> Devices.connect(driver, device_ref)
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
      discovered_devices()
      |> Enum.map(fn {driver, device_ref} ->
        spec = safe_get_spec(device_ref)

        %{
          device_id: device_ref,
          driver: driver,
          connected: spec != nil,
          device_type: spec && spec.type,
          engine_running: engine_running?(device_ref)
        }
      end)

    %{
      devices: connected_devices,
      active_profiles: Profiles.list_active_profile_summaries()
    }
  end

  # Process-dict cache for `Devices.discover/0` — scoped to the Orchestrator
  # GenServer process, so no multi-process concerns. Refreshed only by
  # `refresh_discovered/0` (from `do_connect_all_devices/0`), so a busy
  # LiveView status poll doesn't re-enumerate hidraw/UART on every call.
  defp discovered_devices do
    case Process.get(:orchestrator_discovered_devices) do
      nil -> refresh_discovered()
      devices -> devices
    end
  end

  defp refresh_discovered do
    devices = Devices.discover()
    Process.put(:orchestrator_discovered_devices, devices)
    devices
  end

  defp auto_connect_ha do
    case Loupey.Settings.get_active_ha_config() do
      %{url: url, token: token} ->
        Loupey.HA.connect(%Hassock.Config{url: url, token: token})

      nil ->
        :ok
    end
  rescue
    err ->
      # Stay non-fatal so boot doesn't die on HA unreachable, but surface the
      # reason — silent swallows made this hard to debug in practice.
      Logger.warning("Orchestrator.auto_connect_ha: #{inspect(err)}")
      :ok
  end
end
