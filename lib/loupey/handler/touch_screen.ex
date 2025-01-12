defmodule Loupey.Handler.TouchScreen do
  use GenServer
  require Logger

  defmodule State do
    @moduledoc false
    defstruct [:button_id, :touch_name, :touch_config]
  end

  # Public API

  def start_link({button_id, touch_name, touch_config}) do
    GenServer.start_link(__MODULE__, {button_id, touch_name, touch_config}, name: via_tuple(button_id, touch_name))
  end

  def via_tuple(button_id, touch_name) do
    Loupey.Registry.via_tuple({__MODULE__, button_id, touch_name})
  end

  def draw_state(pid) do
    GenServer.cast(pid, :draw_state)
  end

  # gen_server callbacks

  def init({button_id, touch_name, touch_config}) do
    Logger.info("Starting #{inspect(touch_config)}")
    {:ok, %State{button_id: button_id, touch_name: touch_name, touch_config: touch_config}}
  end

  def handle_cast({:touch_end, _touche_map, {x, y}}, state) do
    Logger.debug("Touch end: #{inspect({x, y})}")
    {:noreply, state}
  end

  def handle_cast(:draw_state, state) do
    img = Loupey.Image.new!(state.touch_config.icon, state.touch_config.max)
    case state.touch_name do
      {:center, key_id} -> Loupey.Handler.LayoutRouter.draw_image_to_key(state.button_id, key_id, img)
      _ -> nil
    end
    {:noreply, state}
  end

  def handle_cast(msg, state) do
    Logger.debug("Unknown message: #{inspect(msg)}")
    {:noreply, state}
  end
end
