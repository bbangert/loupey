defmodule Loupey.Bindings.InputRule do
  @moduledoc """
  Defines what happens when a user interacts with a control.

  An input rule matches on a trigger type (`:press`, `:rotate_cw`, etc.)
  and optionally a `when` condition. When matched, it fires one or more
  actions (call_service, switch_layout, etc.) and may also fire
  one-shot animations (e.g. a flash on press).
  """

  alias Loupey.Animation.Keyframes

  @type trigger ::
          :press | :release | :rotate_cw | :rotate_ccw | :touch_start | :touch_move | :touch_end

  @type t :: %__MODULE__{
          on: trigger(),
          when: String.t() | nil,
          actions: [map()],
          animations: [Keyframes.t()]
        }

  @enforce_keys [:on]
  defstruct [:on, :when, actions: [], animations: []]
end
