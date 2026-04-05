defmodule Loupey.HA.EntityState do
  @moduledoc """
  A snapshot of a Home Assistant entity's state.

  This is the core data type that flows through the system — bindings
  evaluate their rules against this struct to decide what to render
  and which actions to take.
  """

  @type t :: %__MODULE__{
          entity_id: String.t(),
          state: String.t(),
          attributes: map(),
          last_changed: String.t() | nil,
          last_updated: String.t() | nil
        }

  @enforce_keys [:entity_id, :state]
  defstruct [:entity_id, :state, :last_changed, :last_updated, attributes: %{}]
end
