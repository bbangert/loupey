defmodule Loupey.Orchestrator do
  @moduledoc """
  Manages the lifecycle of device connections and binding engines.

  Ties together: discover devices → connect → load active profile →
  start binding engine. Provides a single API for the web UI to
  activate/deactivate profiles on connected devices.
  """

  require Logger

  alias Loupey.Bindings.Engine
  alias Loupey.Devices
  alias Loupey.DeviceServer
  alias Loupey.Profiles

  @doc """
  Discover and connect all available devices.
  If there's an active profile, start binding engines for matching devices.
  """
  def connect_all_devices do
    results = Devices.connect_all()

    case Profiles.get_active_profile() do
      nil ->
        Logger.info("Orchestrator: #{length(results)} device(s) connected, no active profile")

      profile ->
        activate_profile_on_devices(profile)
    end

    results
  end

  @doc """
  Activate a profile: mark it active in the DB, start binding engines
  on all connected devices that match the profile's device type.
  """
  def activate_profile(profile_id) do
    # Deactivate all profiles first
    for p <- Profiles.list_profiles(), p.active do
      deactivate_profile(p.id)
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

  @doc """
  Deactivate a profile: stop any running binding engines, mark inactive.
  """
  def deactivate_profile(profile_id) do
    profile = Profiles.get_profile(profile_id)

    if profile do
      stop_engines_for_profile(profile)
      Profiles.update_profile(profile, %{"active" => false})
      :ok
    else
      {:error, :not_found}
    end
  end

  @doc """
  Reload the active profile on all running engines.
  Called after editing bindings/layouts in the UI.
  """
  def reload_active_profile do
    case Profiles.get_active_profile() do
      nil -> :ok
      profile -> activate_profile_on_devices(profile)
    end
  end

  @doc """
  Get the status of all connected devices and their engines.
  """
  def status do
    connected_devices =
      Devices.discover()
      |> Enum.map(fn {driver, tty} ->
        device_id = tty
        spec = try do
          DeviceServer.get_spec(device_id)
        rescue
          _ -> nil
        catch
          :exit, _ -> nil
        end

        engine_running = engine_running?(device_id)

        %{
          tty: tty,
          device_id: device_id,
          driver: driver,
          connected: spec != nil,
          device_type: spec && spec.type,
          engine_running: engine_running
        }
      end)

    active_profile = Profiles.get_active_profile()

    %{
      devices: connected_devices,
      active_profile: active_profile && %{id: active_profile.id, name: active_profile.name}
    }
  end

  # -- Internal --

  defp activate_profile_on_devices(profile) do
    core_profile = Profiles.to_core_profile(profile)

    for {_driver, tty} <- Devices.discover() do
      device_id = tty

      # Ensure device is connected
      ensure_connected(device_id)

      # Check device type matches
      spec =
        try do
          DeviceServer.get_spec(device_id)
        rescue
          _ -> nil
        catch
          :exit, _ -> nil
        end

      if spec && spec.type == profile.device_type do
        start_or_update_engine(device_id, core_profile)
      end
    end
  end

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

  defp stop_engines_for_profile(_profile) do
    # Stop all engines (we only support one active profile at a time)
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
end
