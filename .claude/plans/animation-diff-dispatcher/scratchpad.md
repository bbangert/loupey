# Scratchpad — v2 Animation Diff Dispatcher

Decisions, dead-ends, and gotchas captured during planning.

## Decisions made (with reasoning)

- **Nested form, not dotted strings** for `transitions` /
  `on_change` property keys. Rationale: matches existing instruction
  nesting, no path-mini-language to invent, internal repr is plain
  `[atom]` lists.
- **`last_match` extends to carry resolved instructions**:
  `{:matched, rule_idx, instructions}` instead of separate map.
  Trivial memory cost per binding, keeps diff machinery local.
- **Synthetic two-stop keyframes for transitions** rather than a new
  per-property tween subsystem. Reuses existing `Tween.lerp_value/3`
  (handles numbers, hex colors, hex+alpha, nested maps).
- **`on_change` only fires on same-idx re-match.** Rule-entry effects
  remain `on_enter`'s job. `:no_match → match` and rule-transition
  paths skip on_change.
- **Transition skipped when old value is nil.** Matches CSS semantics
  (no transition on first paint). on_change still fires (a property
  appearing IS a change).

## Open questions for implementation

- **Cancelling stale per-property one-shots on rapid re-fires**
  (Risks Q4). Plan called for filter-by-stops in Ticker. Resolved
  during Phase 3: went with the rejected alternative (tag
  `InFlight` with `:property_path`) because filter-by-stops would
  also cancel on_change keyframes that happen to lerp the same
  property path directly. The tag approach is a single nilable
  field on `InFlight` with a 1-line filter, and it cleanly
  separates "synthetic transition flight" from "anything else
  in one_shots". Cleaner correctness won over avoiding the
  struct change.
- **String keyframe references in `on_change`** (e.g.
  `on_change: { color: "ripple" }`). Resolved as planned: the
  parser raises on non-map values at recursion level, with a
  message pointing the author to `effect:` shorthand. The
  `@atom_map` whitelist actually atomizes "ripple" → :ripple
  before the walker sees it, so the rejection path catches both
  string and atom forms uniformly.

## Things to remember during implementation

- `@atom_map` whitelist in `yaml_parser.ex` — every new YAML key
  goes there. The existing comment at lines 286–305 explains why.
- `Tween.lerp_value/3` already supports nested-map lerping via
  `Map.merge` recursion. Don't add a parallel implementation.
- The Ticker's `start_animation/5` cast already replaces
  `base_instructions` — the diff dispatcher doesn't need a separate
  refresh path.
- Engine's `match_summary/1` is the gate that keeps non-animated
  rules from interfering with cross-binding cancel_all. Extend it
  to include `transitions` / `on_change` populated rules; do NOT
  bypass it.
- Existing `engine_animation_test.exs` expects
  `last_match == %{key => {:matched, idx}}`. All those assertions
  need updating to the new 3-tuple shape.

## Implementation gotchas (logged after Phase 7)

- **Atom-map intercepts known leaf-name strings before the
  walker.** Authoring `on_change: { color: "ripple" }` ends up
  with `:ripple` (an atom) at the walker, not `"ripple"`. The
  rejection path needs `not is_map(value)`, not just `is_binary`.
- **Dialyzer flags defensive `prev || %{}`.** The `instructions`
  third element of `{:matched, _, instructions}` is always a map
  by construction (Rules.match_output returns a map). Don't add
  defensive nil-coalescing — dialyzer will (correctly) call it
  dead code.
- **Credo's max-depth-2 trips on `Enum.reduce` with a multi-line
  fn that has a nested cond.** Extracted `recurse_on_change_entry/4`
  to keep `walk_on_change/3`'s body shallow.
- **`fire_property_diff_hooks/5` initially used
  `MapSet.union(MapSet.new(Map.keys(transitions)),
  MapSet.new(Map.keys(on_change)))`.** Reviewer caught it; cheaper
  to concat the lists then build one MapSet.

[21:55] WARN: verification-runner did not write reviews/verification.md — agent returned truncated chat ("Let me run all commands sequentially:" with no synthesis). Ran /phx:review's verification fallback directly: format check OK, compile --warnings-as-errors OK, mix test 389/0, credo --strict 0 issues, dialyzer passes (11 errors, 11 skipped — existing skip list). Findings extracted from elixir-reviewer + testing-reviewer + security-analyzer chat returns; security-analyzer noted Write was denied (sandbox restriction on the spawned agent).
