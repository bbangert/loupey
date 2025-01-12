defmodule Loupey.Handler.ButtonController do
  @moduledoc """
  Supervisor that loads the layout router and button handlers. Provides a public API
  for sending messages to the registered layout router.

  """
  require Logger

  def start_link({device, device_handler_pid, config}) do
    children =
      Enum.map(config, &layout_spec/1) ++
        [Loupey.Handler.LayoutRouter.child_spec({device, device_handler_pid})]

    Supervisor.start_link(children, strategy: :one_for_one)
  end

  defp layout_spec({button_id, layout_config}) do
    Supervisor.child_spec(
      Loupey.Handler.Layout.child_spec({button_id, layout_config}),
      id: {Loupey.Handler.Layout, button_id},
      start: {Loupey.Handler.Layout, :start_link, [{button_id, layout_config}]}
    )
  end

  @spec handle_message(Loupey.Device.command()) :: any()
  def handle_message(command) do
    Loupey.Handler.LayoutRouter.handle_message(command)
  end

  def child_spec({device_handler_pid, config}) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [device_handler_pid, config]},
      type: :supervisor
    }
  end
end
