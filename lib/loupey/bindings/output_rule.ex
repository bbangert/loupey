defmodule Loupey.Bindings.OutputRule do
  @moduledoc """
  Defines how a control's display/LED reacts to HA entity state changes.

  Output rules are evaluated top-down; the first rule whose `when` condition
  matches produces render instructions (icon, color, fill, text, background).
  """

  @type t :: %__MODULE__{
          when: String.t() | true,
          instructions: map()
        }

  @enforce_keys [:when, :instructions]
  defstruct [:when, :instructions]
end
