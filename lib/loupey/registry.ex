defmodule Loupey.Registry do
  def start_link() do
    Registry.start_link(name: __MODULE__, keys: :unique)
  end

  def via_tuple(id) do
    {:via, Registry, {__MODULE__, id}}
  end

  def child_spec(_) do
    Supervisor.child_spec(
      Registry,
      id: __MODULE__,
      start: {__MODULE__, :start_link, []}
    )
  end

  def select_touch_buttons(button_id) do
    Registry.select(__MODULE__, [
      {{:"$1", :"$2", :_},
       [{:==, {:element, 1, :"$1"}, Loupey.Handler.TouchScreen},
        {:==, {:element, 2, :"$1"}, button_id}],
       [{{:"$1", :"$2"}}]}
    ])
  end
end
