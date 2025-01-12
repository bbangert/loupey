defmodule Loupey.Handler.LayoutRouter do
  use GenServer
  require Logger

  @moduledoc """
  Router that tracks the active layer and sends messages to the active layer.

  This module uses the `Loupy.Registry` to locate available layers and sends
  messages to the active layer.

  Device commands from an active layer are sent to the device handler.

  """

  defmodule State do
    @moduledoc false
    defstruct [:active_layout, :device, :device_handler_pid]
  end

  # Public API

  def start_link({device, device_handler_pid}, default_layout \\ 0) do
    GenServer.start_link(__MODULE__, {device, device_handler_pid, default_layout},
      name: via_tuple()
    )
  end

  def via_tuple() do
    Loupey.Registry.via_tuple({__MODULE__})
  end

  def handle_message(command) do
    GenServer.cast(via_tuple(), {:handle_message, command})
  end

  def draw_image_to_key(button_id, key_number, image, opts \\ [background_color: "#000000"]) do
    GenServer.cast(via_tuple(), {:draw_image_to_key, button_id, key_number, image, opts})
  end

  # gen_server callbacks

  def init({device, device_handler_pid, default_layout}) do
    Process.send_after(self(), {:draw_all, "#000000"}, 50)
    Process.send_after(self(), :draw_state, 60)

    {:ok,
     %State{active_layout: default_layout, device: device, device_handler_pid: device_handler_pid}}
  end

  def handle_info({:draw_all, color}, state) do
    draw_all(color, state.device.variant_info, state.device_handler_pid)
    {:noreply, state}
  end

  def handle_info(:draw_state, state) do
    draw_state(state)
    {:noreply, state}
  end

  def handle_info(_, state) do
    {:noreply, state}
  end

  def handle_cast({:draw_image_to_key, button_id, key_number, image, opts}, state) do
    if state.active_layout == button_id do
      Loupey.DeviceHandler.draw_image_to_key(state.device_handler_pid, key_number, image, opts)
    end

    {:noreply, state}
  end

  def handle_cast({:handle_message, {:button_press, button_id, :up}}, state) do
    prior_button_id = state.active_layout
    Loupey.DeviceHandler.set_button_color(state.device_handler_pid, prior_button_id, "#000000")
    Loupey.DeviceHandler.set_button_color(state.device_handler_pid, button_id, "#22ff22")
    draw_all("#000000", state.device.variant_info, state.device_handler_pid)
    state = put_in(state.active_layout, button_id)
    draw_state(state)
    {:noreply, state}
  end

  def handle_cast({:handle_message, message}, state) do
    button_id = state.active_layout
    Logger.debug("Layout router received message on layout #{button_id}: #{inspect(message)}")

    case message do
      {:touch_end, touch_map, {x, y, _touch_id, touch_name}} ->
        GenServer.cast(
          Loupey.Handler.TouchScreen.via_tuple(button_id, touch_name),
          {:touch_end, touch_map, {x, y}}
        )

      _ ->
        nil
    end

    {:noreply, state}
  end

  def handle_cast(_, state) do
    {:noreply, state}
  end

  def draw_state(state) do
    Enum.each(Loupey.Registry.select_touch_buttons(state.active_layout), &draw_touch_screen/1)
  end

  def draw_touch_screen({{Loupey.Handler.TouchScreen, _button_id, _touch_name}, pid}) do
    Loupey.Handler.TouchScreen.draw_state(pid)
  end

  def draw_touch_screen(_), do: nil

  def draw_all(color, variant_info, device_handler_pid) do
    Enum.each(
      Map.keys(variant_info.displays),
      &draw_display(color, &1, variant_info, device_handler_pid)
    )
  end

  def draw_display(color, display, variant_info, device_handler_pid) do
    case display do
      :left ->
        Loupey.DeviceHandler.fill_slider(device_handler_pid, :left, color, 100)

      :right ->
        Loupey.DeviceHandler.fill_slider(device_handler_pid, :right, color, 100)

      :center ->
        Enum.each(0..(variant_info.columns * variant_info.rows - 1), fn key_id ->
          Loupey.DeviceHandler.fill_key(device_handler_pid, key_id, color)
        end)
    end
  end
end
