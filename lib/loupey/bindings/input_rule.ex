defmodule Loupey.Bindings.InputRule do
  @moduledoc """
  Defines what happens when a user interacts with a control.

  An input rule matches on a trigger type (`:press`, `:rotate_cw`, etc.)
  and optionally a `when` condition evaluated against entity state.
  When matched, it produces an action (call_service, switch_layout, etc.).
  """

  @type trigger :: :press | :release | :rotate_cw | :rotate_ccw | :touch_start | :touch_move | :touch_end
  @type t :: %__MODULE__{
          on: trigger(),
          when: String.t() | nil,
          action: String.t(),
          params: map()
        }

  @enforce_keys [:on, :action]
  defstruct [:on, :when, :action, params: %{}]
end
