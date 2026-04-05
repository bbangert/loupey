defmodule Loupey.Devices do
  @moduledoc """
  Device discovery and connection management.

  Provides functions to discover connected devices, start device servers
  under the dynamic supervisor, and subscribe to device events.
  """

  @drivers [Loupey.Driver.Loupedeck]

  @doc """
  Discover all supported devices currently connected.

  Returns a list of `{driver_module, tty}` tuples for each matched device.
  """
  @spec discover() :: [{module(), String.t()}]
  def discover do
    Circuits.UART.enumerate()
    |> Enum.flat_map(fn {tty, info} ->
      case Enum.find(@drivers, & &1.matches?(info)) do
        nil -> []
        driver -> [{driver, tty}]
      end
    end)
  end

  @doc """
  Connect to a device and start a DeviceServer under the dynamic supervisor.

  Returns `{:ok, pid}` or `{:error, reason}`.
  """
  @spec connect(module(), String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def connect(driver_module, tty, opts \\ []) do
    device_id = Keyword.get(opts, :device_id, tty)

    child_spec = %{
      id: {Loupey.DeviceServer, device_id},
      start:
        {Loupey.DeviceServer, :start_link,
         [[driver: driver_module, tty: tty, device_id: device_id]]},
      restart: :transient
    }

    DynamicSupervisor.start_child(Loupey.DeviceSupervisor, child_spec)
  end

  @doc """
  Discover and connect all available devices.

  Returns a list of `{:ok, pid}` or `{:error, reason}` results.
  """
  @spec connect_all() :: [{:ok, pid()} | {:error, term()}]
  def connect_all do
    discover()
    |> Enum.map(fn {driver, tty} -> connect(driver, tty) end)
  end

  @doc """
  Subscribe the calling process to events from a device.

  Events are delivered as `{:device_event, device_id, event}` messages.
  """
  @spec subscribe(term()) :: {:ok, pid()} | {:error, term()}
  def subscribe(device_id) do
    Registry.register(Loupey.EventRegistry, device_id, [])
  end
end
