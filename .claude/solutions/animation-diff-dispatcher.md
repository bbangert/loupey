---
problem: Per-property CSS-style transitions and on_change one-shots fired only on same-rule re-matches with diffed resolved instructions
domain: animation
tags: [engine, ticker, keyframes, diffing, css-semantics, yaml-parser]
date: 2026-04-25
---

# Animation Diff Dispatcher (v2)

## Problem

Loupey's `Bindings.Engine` already had a rule-transition dispatcher
that cancel/installed continuous animations on rule_idx changes,
but per-property `transitions` (color tween over 300ms) and
`on_change` (ripple effect on brightness flip) require a *different*
trigger: same matched rule, but resolved instructions changed at a
declared property path. The path mini-language vs nested authoring
shape, the "what counts as a leaf in the YAML walker", and rapid
same-property re-fire stacking were all decisions that needed to
land together.

## Key insights

### Synthetic keyframes piggyback on existing tween primitives
`Tween.lerp_keyframe` + `lerp_value` already handle numbers, hex
colors, hex+alpha, and nested maps via `Map.merge` recursion.
Build a synthetic `%Keyframes{}` with two stops `[{0, nest(path,
old)}, {100, nest(path, new)}]` and the existing pipeline lerps it
correctly. No new interpolation primitive needed.

### Tag flights, don't filter by stop content
For "cancel any in-flight transition for property path P", you can
either filter `one_shots` by checking which flights' keyframe stops
touch P, or tag synthetic transition flights with the path. Tagging
is cleaner: it cleanly distinguishes "synthetic transition flight"
from "on_change/on_enter one-shot whose keyframe happens to lerp
the same property". One nilable `:property_path` field on InFlight
plus a 1-line filter beats fragile content sniffing.

### Top-level YAML atom interning intercepts before walkers
Loupey's `@atom_map` whitelist atomizes known string values during
`atomize_keys/1`. So `on_change: { color: "ripple" }` lands at the
walker as `:ripple` (atom), not `"ripple"` (string). When rejecting
non-map leaf values, use `not is_map(value)` rather than
`is_binary(value)` — otherwise atoms slip through with a confusing
"expected map" error instead of the helpful "string keyframe refs
not supported in on_change" message.

### Non-animated rules collapse to :no_match in match_summary
`last_match` only tracks rules with at least one of {animations,
on_enter, transitions, on_change} populated. Tracking non-animated
rules would let `cancel_all` fire when leaving a non-animated rule,
wiping animations installed by *other bindings* on the same control
(cross-binding interference). The collapse keeps non-animated rules
invisible to the dispatch state machine.

### `prev || %{}` in diff is dead code, not safety
The `last_match` 3-tuple's third element comes from
`Rules.match_output`, which always returns a map for matched
rules. Defensive nil-coalescing on that input is dead code that
dialyzer (correctly) flags. Remove it; trust the contract.

## Files

- `lib/loupey/animation/transition_spec.ex` (struct + parse)
- `lib/loupey/bindings/output_rule.ex` (re-extended)
- `lib/loupey/bindings/yaml_parser.ex` (`parse_transitions/1`,
  `parse_on_change/2`, leaf detection, ambiguity raises)
- `lib/loupey/bindings/engine.ex` (`apply_match_transition/4`,
  `fire_property_diff_hooks/5`, `diff_paths/3`,
  `install_property_transitions/5`, `install_property_on_change/5`,
  `nest/2`, `match_summary/1`, `rule_animated?/1`)
- `lib/loupey/animation/ticker.ex`
  (`start_property_transition/5`, `cancel_property_transition/3`,
  `InFlight.property_path`)

## Tests

- `test/loupey/bindings/yaml_parser_test.exs` (+13 tests)
- `test/loupey/bindings/engine_animation_test.exs` (+12 tests, +4
  shape updates)

## Plan

`.claude/plans/animation-diff-dispatcher/plan.md` —
`progress.md` for what landed; `scratchpad.md` for decisions.
