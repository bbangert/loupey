defmodule Loupey.Bindings.Binding do
  @moduledoc """
  Connects a physical control to behavior via input and output rules.

  - `input_rules` — what happens when the control is activated.
    Each rule can fire multiple actions with explicit targets.
  - `output_rules` — how the control's display/LED reacts to state changes.
    Rules use `state_of("entity_id")` to access any entity's state.
  - `entity_id` — (deprecated, backward compat) legacy single-entity reference.
    New bindings should use `state_of()` in expressions and explicit targets
    in actions instead.
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
