defmodule Loupey.Bindings.Binding do
  @moduledoc """
  Ties a control to an HA entity with input and output rules.

  A binding connects a physical control to behavior:
  - `entity_id` — the HA entity this binding watches/controls (nil for layout switches)
  - `input_rules` — what happens when the control is activated
  - `output_rules` — how the control's display/LED reacts to state changes
  """

  alias Loupey.Bindings.{InputRule, OutputRule}

  @type t :: %__MODULE__{
          entity_id: String.t() | nil,
          input_rules: [InputRule.t()],
          output_rules: [OutputRule.t()]
        }

  @enforce_keys []
  defstruct [:entity_id, input_rules: [], output_rules: []]
end
