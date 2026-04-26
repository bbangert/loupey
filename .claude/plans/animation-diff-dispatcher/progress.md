# Progress — v2 Animation Diff Dispatcher

Implemented in one cycle. All 7 plan phases landed; full verification
suite green; review agents (elixir-reviewer, iron-law-judge) clean.

## What landed

### Loupey.Animation.TransitionSpec (new)
`lib/loupey/animation/transition_spec.ex`. 3-field struct
(`duration_ms`, `easing`) with `parse/1` that resolves the easing
spec at load time and raises on missing `:duration_ms` or unknown
easing. No protocols, no behaviours.

### OutputRule (re-extended)
`lib/loupey/bindings/output_rule.ex`. Added back `:transitions` and
`:on_change` fields with default `%{}`. Both keyed by `[atom]`
property paths — the engine's diff representation, not authoring
shape. Type spec updated; moduledoc updated to describe the diff
semantics (only same-rule re-matches fire these; rule entry/exit
goes through `on_enter` / cancel-and-install paths).

### YAML parser (nested form)
`lib/loupey/bindings/yaml_parser.ex`. New `parse_transitions/1`
and `parse_on_change/2` walkers flatten nested authoring shape into
flat `%{[atom] => spec}` maps. Leaf detection:

- transitions: presence of `:duration_ms` marks a leaf; any other
  key at that level (besides `:easing`) raises ambiguity.
- on_change: presence of `:duration_ms` or `:effect` marks a leaf;
  nested-map values other than `:keyframes` raise as phantom paths.

Top-level `:duration_ms` (path == []) raises — a transition with no
property is meaningless. String keyframe references in `on_change`
also raise (registry refs are deferred).

`@animation_keys` extended with `transition`, `transitions`,
`on_change`. `@atom_map` extended with the same three plus
`on_change` so atomization stays driver-anchored.

### Engine diff dispatcher
`lib/loupey/bindings/engine.ex`.

- `last_match` shape changed from `{:matched, rule_idx} |
  :no_match` to `{:matched, rule_idx, instructions} | :no_match`.
  Animated rules now carry resolved instructions for the next
  dispatch to diff against.
- `match_summary/1` and `rule_animated?/1` decide what's tracked.
  Non-animated rules (no animations / on_enter / transitions /
  on_change) collapse to `:no_match` — same cross-binding-isolation
  rationale as v1.
- `apply_match_transition/4` same-idx branch now refreshes
  continuous animations *and* fires per-property diff hooks.
- `fire_property_diff_hooks/5` walks the union of declared
  `transitions` and `on_change` paths via `diff_paths/3`,
  installing transitions and on_change one-shots for paths whose
  value changed.
- Synthetic transition keyframes are built as two-stop
  `%Keyframes{}` with the value nested at the path
  (`nest([:fill, :amount], 73)` → `%{fill: %{amount: 73}}`).
  `Tween.lerp_keyframe`'s recursive `lerp_value/3` already handles
  numbers, hex colors, hex+alpha, and nested maps — no new
  interpolation primitive needed.
- Transition skipped on `nil → val` (CSS semantics: no transition
  on first paint). `on_change` still fires on first appearance.

### Ticker (per-property transition support)
`lib/loupey/animation/ticker.ex`.

- `InFlight` extended with optional `:property_path`. Default nil
  for non-transition flights (on_enter, on_change, continuous).
- `start_property_transition/5` casts a synthetic transition
  keyframe tagged with the path.
- `cancel_property_transition/3` filters the control's `one_shots`,
  removing only flights with a matching `property_path`. on_change
  and on_enter one-shots (path nil) survive.
- The Engine calls cancel-then-install before each transition so
  rapid re-fires never stack mid-tween.

### Tests
- `test/loupey/bindings/yaml_parser_test.exs`: +13 tests covering
  top-level + nested + multiple paths, transition/on_change
  ambiguity raises, on_change effect shorthand, atom whitelist
  drift-guard. All passing.
- `test/loupey/bindings/engine_animation_test.exs`: +12 diff
  dispatcher tests (same-idx transitions, on_change, combined,
  nil→val, rapid re-fire cancellation, rule-idx change isolation),
  plus 4 existing assertions updated for the new 3-tuple shape. All
  passing.
- Total suite: 389 tests, 0 failures.

### Smoke YAML
`priv/blueprints/animated_examples.yaml`. The "idle breathing
glow" rule now includes `transitions` for `color` and `fill.amount`
plus an `on_change` ripple keyed off `fill.amount`. Loads through
`YamlParser.load_blueprint/1` cleanly; expressions still parse
through the evaluator (existing blueprint smoke test green).

### Docs
`guides/architecture.md` Animation Pipeline section: removed the
"v1-only" note and added a paragraph describing the diff
dispatcher and where it fires (same-rule re-match only).

## v1 deferrals now closed

- ✅ `transitions` field re-added with live dispatch.
- ✅ `on_change` field re-added with live dispatch.
- ✅ Compound dotted-key parsing decision: nested form chosen.
  Authors write nested YAML; parser flattens to `[atom]` paths.

## v1 deferrals still open (out of scope)

- Profile-level `keyframes:` block parsing (unrelated to dispatcher).
- String keyframe references in `on_change` (deferred — raise for
  now; add registry lookup when an authoring case demands it).
- Performance optimization beyond existing 30 fps bench.

## Plan deviation: cancel-by-path implementation

The plan suggested filter-by-stops in `Ticker` for cancelling
stale transitions. I went with the rejected alternative — tag
`InFlight` with `:property_path` — because filter-by-stops conflates
synthetic transitions with on_change keyframes that coincidentally
overlay the same property (e.g. an authored on_change keyframe
that lerps `fill.amount` directly). The tag approach is one extra
nilable field on InFlight and a 1-line filter; cleaner correctness
won over avoiding a struct change. Recorded in scratchpad.

## Verification at completion

Plan's exit criteria:
1. ✅ Blueprint with `transitions: {color: {duration_ms: 300}}` plus
   two state flips renders a smooth color tween — covered by
   `test "fires synthetic two-stop keyframe with old + new values
   at the path"` in `engine_animation_test.exs`.
2. ✅ Blueprint with `on_change: {[:fill, :amount]: ripple}` plus
   a brightness change renders a ripple overlay — covered by
   `test "fires keyframe one-shot on property change"` and the
   smoke YAML's first rule.
3. ✅ Test suite passes; engine_animation_test grew by ≥6
   diff-branch tests (actual: +12).
4. ✅ `mix credo --strict` clean. `mix dialyzer` passes.
5. ✅ This document.

## Commands run

```
mix format --check-formatted
mix compile --warnings-as-errors
mix test                      # 389 tests, 0 failures (20 excluded)
mix credo --strict            # no issues
mix dialyzer                  # passes
```
[21:28] Modified: /var/home/ben/Programming/elixir/loupy/.claude/plans/animation-diff-dispatcher/progress.md
[21:28] Modified: /var/home/ben/Programming/elixir/loupy/.claude/plans/animation-diff-dispatcher/scratchpad.md
[21:28] Modified: /var/home/ben/Programming/elixir/loupy/.claude/plans/animation-diff-dispatcher/scratchpad.md
[21:32] Modified: /var/home/ben/Programming/elixir/loupy/.claude/solutions/animation-diff-dispatcher.md
[21:39] Modified: /var/home/ben/Programming/elixir/loupy/lib/loupey/bindings/yaml_parser.ex
[21:39] Modified: /var/home/ben/Programming/elixir/loupy/lib/loupey/bindings/engine.ex
[21:39] Modified: /var/home/ben/Programming/elixir/loupy/test/loupey/bindings/engine_animation_test.exs
[21:39] Modified: /var/home/ben/Programming/elixir/loupy/test/loupey/bindings/engine_animation_test.exs
[21:39] Modified: /var/home/ben/Programming/elixir/loupy/test/loupey/bindings/engine_animation_test.exs
[21:40] Modified: /var/home/ben/Programming/elixir/loupy/test/loupey/bindings/engine_animation_test.exs
[22:11] Modified: /var/home/ben/Programming/elixir/loupy/.claude/plans/animation-diff-dispatcher/reviews/animation-diff-dispatcher-review.md
[22:14] Modified: /var/home/ben/Programming/elixir/loupy/lib/loupey/animation/ticker.ex
[22:14] Modified: /var/home/ben/Programming/elixir/loupy/lib/loupey/bindings/engine.ex
[22:14] Modified: /var/home/ben/Programming/elixir/loupy/lib/loupey/bindings/engine.ex
[22:14] Modified: /var/home/ben/Programming/elixir/loupy/lib/loupey/bindings/engine.ex
[22:15] Modified: /var/home/ben/Programming/elixir/loupy/lib/loupey/bindings/yaml_parser.ex
[22:16] Modified: /var/home/ben/Programming/elixir/loupy/lib/loupey/bindings/yaml_parser.ex
[22:16] Modified: /var/home/ben/Programming/elixir/loupy/test/loupey/bindings/engine_animation_test.exs
[22:16] Modified: /var/home/ben/Programming/elixir/loupy/test/loupey/bindings/engine_animation_test.exs
[22:21] Modified: /var/home/ben/Programming/elixir/loupy/lib/loupey/graphics/renderer.ex
[22:21] Modified: /var/home/ben/Programming/elixir/loupy/lib/loupey/graphics/renderer.ex
[22:21] Modified: /var/home/ben/Programming/elixir/loupy/lib/loupey/graphics/renderer.ex
[22:22] Modified: /var/home/ben/Programming/elixir/loupy/lib/loupey/bindings/layout_engine.ex
[22:22] Modified: /var/home/ben/Programming/elixir/loupy/lib/loupey/bindings/layout_engine.ex
[22:23] Modified: /var/home/ben/Programming/elixir/loupy/test/loupey/graphics/renderer_test.exs
[22:35] Modified: /var/home/ben/Programming/elixir/loupy/lib/loupey/schemas/binding.ex
[22:35] Modified: /var/home/ben/Programming/elixir/loupy/lib/loupey/profiles.ex
[22:35] Modified: /var/home/ben/Programming/elixir/loupy/lib/loupey/profiles.ex
[22:35] Modified: /var/home/ben/Programming/elixir/loupy/test/loupey/schemas/binding_test.exs
[22:41] Modified: /var/home/ben/Programming/elixir/loupy/guides/binding-editor.md
[22:54] Modified: /var/home/ben/Programming/elixir/loupy/lib/loupey/animation/ticker.ex
[22:54] Modified: /var/home/ben/Programming/elixir/loupy/lib/loupey/animation/ticker.ex
[22:55] Modified: /var/home/ben/Programming/elixir/loupy/lib/loupey/bindings/engine.ex
[22:55] Modified: /var/home/ben/Programming/elixir/loupy/lib/loupey/bindings/engine.ex
[22:55] Modified: /var/home/ben/Programming/elixir/loupy/lib/loupey/bindings/engine.ex
[22:56] Modified: /var/home/ben/Programming/elixir/loupy/test/loupey/animation/ticker_test.exs
[22:57] Modified: /var/home/ben/Programming/elixir/loupy/test/loupey/bindings/engine_animation_test.exs
[07:26] Modified: /var/home/ben/Programming/elixir/loupy/lib/loupey/animation/ticker.ex
[07:26] Modified: /var/home/ben/Programming/elixir/loupy/guides/binding-editor.md
[07:26] Modified: /var/home/ben/Programming/elixir/loupy/guides/architecture.md
[07:26] Modified: /var/home/ben/Programming/elixir/loupy/lib/loupey/bindings/yaml_parser.ex
[07:26] Modified: /var/home/ben/Programming/elixir/loupy/lib/loupey/bindings/yaml_parser.ex
[07:28] Modified: /var/home/ben/Programming/elixir/loupy/test/loupey/bindings/yaml_parser_test.exs
