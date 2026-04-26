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
  - `:transitions` — per-property tweens fired when the rule still
    matches but the resolved value at the property path changed
    (e.g. a 300 ms ease on `color` when the entity's brightness
    template re-resolves). Map keyed by `[atom]` property path,
    valued by `Loupey.Animation.TransitionSpec`.
  - `:on_change` — per-property one-shot keyframes fired on the same
    re-match condition (e.g. a `ripple` overlay when `fill.amount`
    changes). Map keyed by `[atom]` property path, valued by
    `Loupey.Animation.Keyframes`.

  Diff semantics: `transitions` and `on_change` only fire on
  *same-rule re-matches* — when the rule remains the matched rule
  but a property's resolved value changed. Rule entry/exit is the
  job of `on_enter` and the `cancel_all + install` rule-transition
  path. A property appearing for the first time (`nil → val`) skips
  the transition (no value to lerp from) but does fire `on_change`.
  """

  alias Loupey.Animation.{Keyframes, TransitionSpec}

  @type path :: [atom()]

  @type t :: %__MODULE__{
          when: String.t() | true,
          instructions: map(),
          animations: [Keyframes.t()],
          on_enter: [Keyframes.t()],
          transitions: %{path() => TransitionSpec.t()},
          on_change: %{path() => Keyframes.t()}
        }

  @enforce_keys [:when, :instructions]
  defstruct [
    :when,
    :instructions,
    animations: [],
    on_enter: [],
    transitions: %{},
    on_change: %{}
  ]
end
