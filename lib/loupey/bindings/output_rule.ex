defmodule Loupey.Bindings.OutputRule do
  @moduledoc """
  Defines how a control's display/LED reacts to HA entity state changes.

  Output rules are evaluated top-down; the first rule whose `when` condition
  matches produces render instructions (icon, color, fill, text, background).

  Animation hooks layer on top of the resolved instructions:

  - `:animations` — continuous keyframe loops that run while this rule
    is the matched rule (e.g. a breathing glow).
  - `:on_enter` — one-shot effects fired the instant this rule becomes
    the matched rule (e.g. a flash on layout entry).

  Per-property `:transitions` (tweens triggered when a resolved
  property value changes) and `:on_change` (one-shots keyed by
  property) ship in v2 once the diff dispatcher is in place — see
  `.claude/plans/css-style-rendering/progress.md`.
  """

  alias Loupey.Animation.Keyframes

  @type t :: %__MODULE__{
          when: String.t() | true,
          instructions: map(),
          animations: [Keyframes.t()],
          on_enter: [Keyframes.t()]
        }

  @enforce_keys [:when, :instructions]
  defstruct [:when, :instructions, animations: [], on_enter: []]
end
