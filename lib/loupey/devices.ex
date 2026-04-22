defmodule Loupey.Devices do
  @moduledoc """
  Device discovery and connection management.

  Provides functions to discover connected devices, start device servers
  under the dynamic supervisor, and subscribe to device events.

  Supports two transports:

  - `Circuits.UART` enumeration for Loupedeck (WebSocket-over-UART).
  - `HID.enumerate/0` for Elgato Stream Deck and other HID devices.

  Each registered driver provides `matches?/1` which is called with a map
  containing `:vendor_id` and `:product_id` (plus other transport-specific
  fields). The first driver that matches owns the device.
  """

  @drivers [Loupey.Driver.Loupedeck, Loupey.Driver.Streamdeck]

  @doc """
  Return all registered driver modules.
  """
  @spec drivers() :: [module()]
  def drivers, do: @drivers

  @doc """
  Return the driver module for a given device-type string (e.g. "Loupedeck Live").
  Returns `nil` if no driver produces that type.
  """
  @spec driver_for_type(String.t()) :: module() | nil
  def driver_for_type(device_type) do
    Enum.find(@drivers, fn d -> d.device_spec().type == device_type end)
  end

  @doc """
  Return a `Loupey.Device.Spec` for each registered driver.
  """
  @spec all_device_specs() :: [Loupey.Device.Spec.t()]
  def all_device_specs, do: Enum.map(@drivers, & &1.device_spec())

  @doc """
  Discover all supported devices currently connected across UART and HID
  transports.

  Returns a list of `{driver_module, device_ref}` tuples. `device_ref` is
  the transport-specific identifier passed to `driver.open/2` — a tty
  path for UART devices, a hidraw path (e.g. `/dev/hidraw10`) for HID.
  """
  @spec discover() :: [{module(), term()}]
  def discover do
    uart_matches() ++ hid_matches()
  end

  defp uart_matches do
    Circuits.UART.enumerate()
    |> Enum.flat_map(fn {device_ref, info} -> find_driver(info, device_ref) end)
  end

  defp hid_matches do
    HID.enumerate()
    |> Enum.flat_map(fn info -> find_driver(info, info.path) end)
  rescue
    e ->
      log_hid_failure_once(e)
      []
  end

  # `discover/0` is called on every dashboard status poll; logging a warning
  # on each failed HID enumeration would spam the log and drown other output.
  # Log the first failure at :warning, then go quiet until the VM restarts.
  @hid_failure_flag {__MODULE__, :hid_enumerate_failed}

  defp log_hid_failure_once(exception) do
    unless :persistent_term.get(@hid_failure_flag, false) do
      require Logger

      Logger.warning(
        "HID enumeration failed: #{Exception.message(exception)} — Stream Deck devices will not be discovered. " <>
          "Check that libhidapi + libusb are installed (see README). This warning will be logged only once."
      )

      :persistent_term.put(@hid_failure_flag, true)
    end
  end

  defp find_driver(info, device_ref) do
    case Enum.find(@drivers, & &1.matches?(info)) do
      nil -> []
      driver -> [{driver, device_ref}]
    end
  end

  @doc """
  Connect to a device and start a DeviceServer under the dynamic supervisor.

  Returns `{:ok, pid}` or `{:error, reason}`.
  """
  @spec connect(module(), term(), keyword()) :: {:ok, pid()} | {:error, term()}
  def connect(driver_module, device_ref, opts \\ []) do
    device_id = Keyword.get(opts, :device_id, device_ref)

    child_spec = %{
      id: {Loupey.DeviceServer, device_id},
      start:
        {Loupey.DeviceServer, :start_link,
         [[driver: driver_module, device_ref: device_ref, device_id: device_id]]},
      restart: :transient
    }

    DynamicSupervisor.start_child(Loupey.DeviceSupervisor, child_spec)
  end

  @doc """
  Discover and connect all available devices.

  Returns a list of `{:ok, pid}` or `{:error, reason}` results.
  """
  @spec connect_all() :: [{:ok, pid()} | {:error, term()}]
  def connect_all, do: connect_all(discover())

  @doc """
  Connect to a pre-discovered list of devices. Use when the caller has
  already paid for a `discover/0` pass (e.g. `Orchestrator` caches
  discovery) and wants to avoid a redundant hidraw/UART scan.
  """
  @spec connect_all([{module(), term()}]) :: [{:ok, pid()} | {:error, term()}]
  def connect_all(devices) when is_list(devices) do
    Enum.map(devices, fn {driver, device_ref} -> connect(driver, device_ref) end)
  end

  @doc """
  Subscribe the calling process to events from a device.

  Events are delivered as `{:device_event, device_id, event}` messages.
  """
  @spec subscribe(term()) :: :ok | {:error, term()}
  def subscribe(device_id) do
    Phoenix.PubSub.subscribe(Loupey.PubSub, "device:#{device_id}")
  end
end
