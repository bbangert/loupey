defmodule Loupey.Driver do
  @moduledoc """
  Behaviour for device drivers.

  A driver owns the entire I/O stack for a device family — transport (UART,
  USB-HID, …), framing, any protocol-specific state (transaction IDs,
  keep-alives, chunking). `Loupey.DeviceServer` is transport-agnostic: it
  only asks the driver to `open/2` a connection, `send_command/2` encoded
  bytes, and `parse/2` incoming `{:device_data, bytes}` messages that the
  driver forwards from its transport.

  All logic for interpreting events and deciding what to render lives
  outside the driver in the binding engine.
  """

  @doc """
  Return the `Loupey.Device.Spec` for this driver's device type.
  """
  @callback device_spec() :: Loupey.Device.Spec.t()

  @doc """
  Check if the given device info (from `Circuits.UART.enumerate/0`,
  `HID.enumerate/2`, etc.) matches this driver.
  """
  @callback matches?(device_info :: map()) :: boolean()

  @doc """
  Open a connection to the device.

  `device_ref` is an opaque identifier supplied by the discovery layer
  (e.g. a UART tty path, a hidraw path, an hidapi struct, or a test pid).
  Its shape is meaningful only to the driver.

  `opts` must include `:parent` — the pid that will receive
  `{:device_data, binary}` messages as bytes arrive from the transport.
  The returned `connection` is opaque; it is passed back to
  `send_command/2` and `close/1`.
  """
  @callback open(device_ref :: term(), opts :: keyword()) ::
              {:ok, connection :: term()} | {:error, term()}

  @doc """
  Close the connection and release all transport resources.
  """
  @callback close(connection :: term()) :: :ok

  @doc """
  Send an encoded command (from `encode/1` or `encode_refresh/1`) over
  the transport. The driver is responsible for any framing, chunking, or
  per-connection stateful bookkeeping (e.g. transaction IDs).
  """
  @callback send_command(connection :: term(), {byte(), binary()}) ::
              :ok | {:error, term()}

  @doc """
  Parse a raw binary frame from the device into normalized events.
  Returns updated driver state and a list of events.

  The `driver_state` holds mutable protocol state like active touches or
  last-known key states.
  """
  @callback parse(driver_state :: term(), raw :: binary()) ::
              {driver_state :: term(), [Loupey.Events.t()]}

  @doc """
  Encode a render command into `{command_byte, payload_binary}` ready for
  `send_command/2`.
  """
  @callback encode(Loupey.RenderCommands.t()) :: {byte(), binary()}

  @doc """
  Encode a refresh-display command. Only implemented by drivers whose protocol
  requires an explicit commit step after writing a framebuffer (e.g. Loupedeck).
  Drivers that update atomically (e.g. Stream Deck) omit this callback.
  """
  @callback encode_refresh(display_id :: binary()) :: {byte(), binary()}

  @optional_callbacks encode_refresh: 1
end
