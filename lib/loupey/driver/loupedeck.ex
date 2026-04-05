defmodule Loupey.Driver.Loupedeck do
  @moduledoc """
  Driver for Loupedeck devices (Live, CT, etc.).

  Handles the WebSocket-over-UART protocol, message parsing, and command encoding
  specific to Loupedeck hardware.
  """

  @behaviour Loupey.Driver

  alias Loupey.Device.{Spec, Variant}
  alias Loupey.Events.{PressEvent, RotateEvent, TouchEvent}
  alias Loupey.RenderCommands.{DrawBuffer, SetBrightness, SetLED}

  @ws_upgrade_header "GET /index.html\nHTTP/1.1\nConnection: Upgrade\nUpgrade: websocket\nSec-WebSocket-Key: 123abc\n\n"
  @ws_close_frame <<0x88, 0x80, 0x00, 0x00, 0x00, 0x00>>

  @commands %{
    button_press: 0x00,
    knob_rotate: 0x01,
    set_color: 0x02,
    serial: 0x03,
    reset: 0x06,
    version: 0x07,
    set_brightness: 0x09,
    framebuff: 0x10,
    set_vibration: 0x1B,
    mcu: 0x0D,
    draw: 0x0F,
    touch: 0x4D,
    touch_ct: 0x52,
    touch_end: 0x6D,
    touch_end_ct: 0x72
  }

  @max_brightness 10

  # Hardware button ID → control_id mapping
  @button_ids %{
    0x00 => :knob_ct,
    0x01 => :knob_tl,
    0x02 => :knob_cl,
    0x03 => :knob_bl,
    0x04 => :knob_tr,
    0x05 => :knob_cr,
    0x06 => :knob_br,
    0x07 => {:button, 0},
    0x08 => {:button, 1},
    0x09 => {:button, 2},
    0x0A => {:button, 3},
    0x0B => {:button, 4},
    0x0C => {:button, 5},
    0x0D => {:button, 6},
    0x0E => {:button, 7},
    0x0F => :home,
    0x10 => :undo,
    0x11 => :keyboard,
    0x12 => :enter,
    0x13 => :save,
    0x14 => :fn_l,
    0x15 => :a,
    0x16 => :c,
    0x17 => :fn_r,
    0x18 => :b,
    0x19 => :d,
    0x1A => :e
  }

  # Reverse map: control_id → hardware button ID
  @control_to_hw Map.new(@button_ids, fn {hw, ctrl} -> {ctrl, hw} end)

  @variants [Variant.Live]

  defmodule DriverState do
    @moduledoc false
    defstruct [:variant, :spec, touches: %{}]
  end

  defmodule ConnectionState do
    @moduledoc false
    defstruct [:uart_pid, :tty]
  end

  # -- Driver behaviour --

  @impl true
  def device_spec, do: Variant.Live.device_spec()

  @impl true
  def matches?(device_info) do
    Enum.any?(@variants, & &1.is_variant?(device_info))
  end

  @impl true
  def connect(tty, _opts \\ []) do
    # Start UART unlinked so we control its lifecycle explicitly.
    # If we link, a crash during init can orphan the UART holding the tty.
    {:ok, uart_pid} = Circuits.UART.start_link()

    try do
      with :ok <- Circuits.UART.open(uart_pid, tty, speed: 256_000, active: false),
           # Send the WebSocket close frame first in case the device is still in
           # an active session from a prior unclean disconnect.
           _ <- Circuits.UART.write(uart_pid, @ws_close_frame),
           # Small delay to let the device process the close and reset.
           _ <- Process.sleep(50),
           # Drain any buffered data from the prior session.
           _ <- drain_uart(uart_pid),
           # Now start a fresh WebSocket handshake.
           :ok <- Circuits.UART.write(uart_pid, @ws_upgrade_header),
           {:ok, _upgrade_response} <- Circuits.UART.read(uart_pid, 2000),
           # Drain any extra data sent right after upgrade.
           _ <- drain_uart(uart_pid),
           :ok <-
             Circuits.UART.configure(uart_pid,
               framing: {Loupey.Framing.Websocket, []},
               active: true
             ) do
        {:ok, %ConnectionState{uart_pid: uart_pid, tty: tty}}
      else
        {:error, _} = error ->
          force_cleanup(uart_pid)
          error
      end
    rescue
      e ->
        force_cleanup(uart_pid)
        {:error, e}
    end
  end

  @impl true
  def disconnect(%ConnectionState{uart_pid: uart_pid}) do
    # Best-effort close: send WS close frame, then tear down UART.
    # Each step is wrapped to ensure we always reach stop/1.
    try do
      Circuits.UART.write(uart_pid, @ws_close_frame)
    catch
      _, _ -> :ok
    end

    try do
      Circuits.UART.close(uart_pid)
    catch
      _, _ -> :ok
    end

    try do
      Circuits.UART.stop(uart_pid)
    catch
      _, _ -> :ok
    end

    :ok
  end

  # Drain all buffered data from UART so we start clean.
  defp drain_uart(uart_pid) do
    case Circuits.UART.read(uart_pid, 100) do
      {:ok, ""} -> :ok
      {:ok, _data} -> drain_uart(uart_pid)
      {:error, :etimedout} -> :ok
      _ -> :ok
    end
  end

  # Force cleanup of UART process regardless of state.
  defp force_cleanup(uart_pid) do
    try do
      Circuits.UART.close(uart_pid)
    catch
      _, _ -> :ok
    end

    try do
      Circuits.UART.stop(uart_pid)
    catch
      _, _ -> :ok
    end
  end

  @impl true
  def send_raw(%ConnectionState{uart_pid: uart_pid}, data) do
    Circuits.UART.write(uart_pid, data)
  end

  @impl true
  def parse(driver_state, <<_, command_byte, _transaction_id, data::binary>>) do
    command = parse_command_byte(command_byte)

    case command do
      :button_press -> {driver_state, parse_button_press(data)}
      :knob_rotate -> {driver_state, parse_knob_rotate(data)}
      :touch -> parse_touch(driver_state, :touch, data)
      :touch_end -> parse_touch(driver_state, :touch_end, data)
      _ -> {driver_state, []}
    end
  end

  def parse(driver_state, _), do: {driver_state, []}

  @impl true
  def encode(%DrawBuffer{} = cmd) do
    spec = device_spec()
    control = Spec.find_control(spec, cmd.control_id)
    display = control.display

    {x, y} =
      case display.offset do
        nil -> {cmd.x, cmd.y}
        {ox, oy} -> {cmd.x + ox, cmd.y + oy}
      end

    header = <<x::16, y::16, cmd.width::16, cmd.height::16>>
    {@commands.framebuff, <<display.display_id::binary, header::binary, cmd.pixels::binary>>}
  end

  def encode(%SetLED{control_id: control_id, color: color}) do
    hw_id = Map.fetch!(@control_to_hw, control_id)
    [r, g, b] = Loupey.Color.parse_color(color)
    {@commands.set_color, <<hw_id, r, g, b>>}
  end

  def encode(%SetBrightness{level: level}) do
    byte = max(0, min(@max_brightness, round(level * @max_brightness)))
    {@commands.set_brightness, byte}
  end

  @doc """
  Encode a refresh command for a display. Display ID comes from the control's display spec.
  """
  def encode_refresh(display_id_binary) do
    {@commands.draw, display_id_binary}
  end

  # -- Public helpers --

  @doc """
  Create a new driver state for parsing.
  """
  def new_driver_state(variant \\ Variant.Live) do
    %DriverState{variant: variant, spec: variant.device_spec()}
  end

  @doc """
  Find the variant for a device from enumeration info.
  """
  def find_variant(device_info) do
    Enum.find(@variants, & &1.is_variant?(device_info))
  end

  # -- Internal parsing --

  defp parse_command_byte(byte) do
    case Enum.find(@commands, fn {_, v} -> v == byte end) do
      {cmd, _} -> cmd
      nil -> :unknown
    end
  end

  defp parse_button_press(<<hw_id, 0x00>>) do
    case Map.get(@button_ids, hw_id) do
      nil -> []
      control_id -> [%PressEvent{control_id: control_id, action: :press}]
    end
  end

  defp parse_button_press(<<hw_id, _>>) do
    case Map.get(@button_ids, hw_id) do
      nil -> []
      control_id -> [%PressEvent{control_id: control_id, action: :release}]
    end
  end

  defp parse_button_press(_), do: []

  defp parse_knob_rotate(<<hw_id, delta>>) do
    case Map.get(@button_ids, hw_id) do
      nil ->
        []

      control_id ->
        direction = if delta == 1, do: :cw, else: :ccw
        [%RotateEvent{control_id: control_id, direction: direction}]
    end
  end

  defp parse_knob_rotate(_), do: []

  defp parse_touch(driver_state, command, <<_, x::unsigned-big-16, y::unsigned-big-16, touch_id>>) do
    spec = driver_state.spec
    control = Spec.resolve_touch(spec, x, y)

    if control do
      {ox, oy} = control.display.offset || {0, 0}
      local_x = x - ox
      local_y = y - oy

      action =
        case command do
          :touch_end -> :end
          _ when is_map_key(driver_state.touches, touch_id) -> :move
          _ -> :start
        end

      touches =
        case action do
          :end -> Map.delete(driver_state.touches, touch_id)
          _ -> Map.put(driver_state.touches, touch_id, {x, y, control.id})
        end

      event = %TouchEvent{
        control_id: control.id,
        action: action,
        x: local_x,
        y: local_y,
        touch_id: touch_id
      }

      {%{driver_state | touches: touches}, [event]}
    else
      {driver_state, []}
    end
  end

  defp parse_touch(driver_state, _, _), do: {driver_state, []}
end
