defmodule Loupey.Driver do
  @moduledoc """
  Behaviour for device drivers.

  A driver handles the transport layer (UART, USB HID, etc.) and protocol
  (WebSocket frames, HID reports, etc.) for a specific device family.
  It provides:

  - Connection management (connect/disconnect)
  - Raw data sending
  - Parsing raw bytes into normalized `Loupey.Events`
  - Encoding `Loupey.RenderCommands` into device-specific binary
  - Device discovery and identification

  The driver is a thin I/O boundary. All logic for interpreting events
  and deciding what to render lives outside the driver in the binding engine.
  """

  @doc """
  Return the `Loupey.Device.Spec` for this driver's device type.
  """
  @callback device_spec() :: Loupey.Device.Spec.t()

  @doc """
  Check if the given device info (e.g., from UART enumeration) matches this driver.
  """
  @callback matches?(device_info :: map()) :: boolean()

  @doc """
  Connect to the device. Returns `{:ok, connection_state}` or `{:error, reason}`.
  The connection_state is opaque to callers and passed back to other callbacks.
  """
  @callback connect(tty :: String.t(), opts :: keyword()) ::
              {:ok, connection_state :: term()} | {:error, term()}

  @doc """
  Disconnect from the device.
  """
  @callback disconnect(connection_state :: term()) :: :ok

  @doc """
  Send raw binary data to the device.
  """
  @callback send_raw(connection_state :: term(), data :: iodata()) :: :ok | {:error, term()}

  @doc """
  Parse a raw binary frame from the device into normalized events.
  Returns updated driver state and a list of events.

  The driver_state holds mutable protocol state like active touches.
  """
  @callback parse(driver_state :: term(), raw :: binary()) ::
              {driver_state :: term(), [Loupey.Events.t()]}

  @doc """
  Encode a render command into the binary format expected by the device.
  Returns `{command_byte, payload_binary}` ready for framing.
  """
  @callback encode(Loupey.RenderCommands.t()) :: {non_neg_integer(), binary()}
end
