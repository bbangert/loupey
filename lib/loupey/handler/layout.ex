defmodule Loupey.Handler.Layout do
  require Logger

  def start_link({button_id, layout_config}) do
    children =
      Enum.map(layout_config, &touch_spec(button_id, &1))

    Supervisor.start_link(children, strategy: :one_for_one)
  end

  defp touch_spec(button_id, {touch_name, touch_config}) do
    Supervisor.child_spec(
      {Loupey.Handler.TouchScreen, [button_id, touch_name]},
      id: {Loupey.Handler.TouchScreen, button_id, touch_name},
      start: {Loupey.Handler.TouchScreen, :start_link, [{button_id, touch_name, touch_config}]}
    )
  end

  def child_spec({device_handler_pid, config}) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [device_handler_pid, config]},
      type: :supervisor
    }
  end
end
