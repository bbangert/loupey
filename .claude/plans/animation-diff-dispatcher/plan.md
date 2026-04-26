# Plan — v2 Animation Diff Dispatcher

Per-property `transitions` and `on_change` for the resolved-instructions
diff dispatcher in `Loupey.Bindings.Engine`. Re-introduces fields that
were stripped from `OutputRule` in W1 of the PR-14 review and wires them
to live dispatch.

Source context:
- v1 progress / handoff: `.claude/plans/css-style-rendering/progress.md`
- W1 finding (strip rationale): `.claude/plans/css-style-rendering/reviews/css-style-rendering-review.md`
- Original interview / motivating cases:
  `.claude/plans/css-style-rendering/interview.md` (Cases 2 + 5)

## Scope

**In scope**
- Re-add `transitions` and `on_change` fields to `OutputRule` with
  v2 dispatch wired (no speculative storage).
- Engine same-rule re-match path: diff prev resolved instructions →
  fire per-property transition tweens and `on_change` one-shots.
- YAML parser support — **nested form only** (decision below).
- Engine integration tests for diff dispatch, rule-vs-property
  precedence, first-match suppression.
- Smoke YAML update to exercise both hooks.

**Out of scope (explicitly deferred)**
- Compound dotted-key parse-time support (`"fill.amount"` as a YAML
  key). Decision: **migrate spec to nested form** — simpler, matches
  existing instruction nesting, no path mini-language to invent. The
  `interview.md` Case 5 sketch will be re-rendered as nested in the
  smoke YAML.
- Profile-level `keyframes:` block parsing (already deferred in v1,
  unrelated to this dispatcher).
- Performance optimization beyond the existing 30 fps bench. Diffs run
  on entity-state changes (already non-hot-path), not in the tick loop.

## Decision: Nested vs dotted property keys

**Chosen: nested.** YAML authors write:

```yaml
output_rules:
  - when: 'state == "on"'
    color: "#FFD700"
    fill:
      amount: '{{ attr("brightness_pct") }}'
      direction: to_top
    transitions:
      color: { duration_ms: 300, easing: ease_out }   # top-level prop
      fill:
        amount: { duration_ms: 200, easing: ease_out }  # nested prop
    on_change:
      fill:
        amount:
          effect: ripple
          duration_ms: 400
          easing: ease_out
          color: "#FFFFFF80"
```

Why nested over dotted (`"fill.amount"`):
1. Matches the rest of the YAML idiom (instructions are nested).
2. Avoids inventing a path-escape mini-language.
3. Engine path representation `[:fill, :amount]` is idiomatic Elixir.
4. CSS-similarity argument is weak — CSS doesn't actually use dotted
   paths; dashed names (`border-color`) are flat shorthands, not paths.

The parser flattens nested YAML at parse time to
`%{[:color] => spec, [:fill, :amount] => spec}` — the path keys are
the engine's diff representation, not authored shape.

Leaf detection: the parser walks down until it hits a map containing
`:duration_ms` (transition spec) or `:duration_ms`/`:effect`/`:keyframes`
(keyframe spec for `on_change`). That's the leaf; parent map keys form
the path.

## Architecture (one paragraph)

The Engine's `apply_match_transition/4` already routes four cases:
`:no_match → :no_match`, `match → :no_match`, `:no_match → match`,
`match → match (diff idx)`, and `match → match (same idx)`. v2 extends
the **same-idx** branch: when the rule still matches but the resolved
instructions changed, walk `rule.transitions` and `rule.on_change` to
fire one-shots per changed property. Transitions are dispatched as
synthetic `%Keyframes{}` whose two stops carry the old and new property
value at the path — the existing `Tween.lerp_value/3` already handles
numbers, hex colors, hex+alpha, and nested maps via recursive merge,
so no new interpolation primitives are needed. `on_change` reuses the
existing one-shot path (`Ticker.start_animation/5` with `:one_shot`).
The `last_match` map grows from `{:matched, rule_idx}` to
`{:matched, rule_idx, instructions}` so the diff has the prior shape
to compare against.

## Iron Law check

- **Code that ships dispatched.** No speculative fields — both
  `transitions` and `on_change` get test-covered live dispatch in this
  plan. Re-introduction is paired with wiring, not separate.
- **No new abstractions for hypothetical use.** Path representation is
  a plain `[atom]` list, not a path-typeclass. `TransitionSpec` is a
  3-field struct (no behaviours/protocols).
- **Diff at the boundary.** The diff runs only on entity-state changes
  (Engine cast/handle_info), never per-tick.
- **Reuse existing primitives.** `Tween.lerp_value/3` already does
  numeric/color/nested-map interpolation; transitions piggyback as
  synthetic two-stop keyframes rather than introducing a new
  per-property tween machinery.

## Files affected

```
lib/loupey/animation/transition_spec.ex          # NEW — small spec struct
lib/loupey/bindings/output_rule.ex               # +transitions, +on_change
lib/loupey/bindings/yaml_parser.ex               # parse nested transitions/on_change
lib/loupey/bindings/engine.ex                    # diff dispatcher + last_match shape
test/loupey/bindings/yaml_parser_test.exs        # +transitions/on_change parse tests
test/loupey/bindings/engine_animation_test.exs   # +diff dispatch tests
priv/blueprints/animated_examples.yaml           # exercise transitions/on_change
.claude/plans/animation-diff-dispatcher/         # this plan + scratchpad + progress
guides/architecture.md                           # +diff-dispatcher behavior note
```

## Phases

### Phase 1 — Spec types + struct re-introduction

- [ ] `[ecto-not-applicable]` Add `Loupey.Animation.TransitionSpec`
  struct in `lib/loupey/animation/transition_spec.ex`:
  ```elixir
  @enforce_keys [:duration_ms, :easing]
  defstruct [:duration_ms, :easing]
  @type t :: %__MODULE__{duration_ms: pos_integer(), easing: Easing.easing_fn()}
  ```
  with a `parse/1` that takes an atom-keyed map (`%{duration_ms:
  300, easing: :ease_out}`) and produces the struct via
  `Easing.resolve/1`. `parse/1` raises `ArgumentError` on missing
  `:duration_ms` or unknown easing — fail loud at load time.
- [ ] Re-add fields to `Loupey.Bindings.OutputRule`:
  ```elixir
  defstruct [:when, :instructions,
             animations: [], on_enter: [],
             transitions: %{}, on_change: %{}]
  ```
  with `@type t :: %__MODULE__{...}` updated. Map keys are
  `[atom]` paths; values are `TransitionSpec.t()` for `transitions`
  and `Keyframes.t()` for `on_change`.
- [ ] Update `OutputRule` moduledoc to remove the "v2 deferral" note —
  v2 has landed.
- [ ] `mix compile --warnings-as-errors` — should pass with the
  parser still emitting empty `transitions: %{}, on_change: %{}` (no
  parser changes yet).

### Phase 2 — YAML parser (nested form)

- [ ] Add `transition`, `transitions`, `on_change` to the
  `@animation_keys` list in `pop_animation_keys/1` so they're
  pulled out of `instructions` cleanly.
- [ ] Add `transition`, `transitions`, `on_change`, `transition_spec`
  (only those that were removed in W1) back to `@atom_map`.
- [ ] Implement `parse_transitions/2` walking nested atom-keyed maps.
  Recursion terminates when the current map contains `:duration_ms`
  but no nested-map values (i.e. leaf transition spec). Emits
  `%{[atom] => %TransitionSpec{}}`.
- [ ] Implement `parse_on_change/2` walking the same shape; leaf
  detection: presence of `:duration_ms` OR `:effect` OR `:keyframes`.
  Emits `%{[atom] => %Keyframes{}}` via `Keyframes.parse/1` for inline
  forms (and registry lookup if string-named — but `on_change`
  per-property doesn't accept registry refs in v2; raise if we see a
  string here, defer registry refs to a future iteration if needed).
- [ ] Wire both into `parse_output_rule/2`:
  ```elixir
  %OutputRule{
    when: condition,
    instructions: atomize_keys(instructions),
    animations: parse_animations(animation_keys, opts),
    on_enter: parse_animation_list(animation_keys["on_enter"], opts),
    transitions: parse_transitions(animation_keys["transitions"] || animation_keys["transition"], opts),
    on_change: parse_on_change(animation_keys["on_change"], opts)
  }
  ```
- [ ] Add YAML parser tests for transition + on_change. See
  Phase 5 for the test list.

### Phase 3 — Engine diff dispatcher

- [ ] Extend `last_match` shape: `{:matched, rule_idx, instructions}
  | :no_match`. Update the `State` moduledoc.
- [ ] Update `match_summary/1` to carry resolved instructions for
  matched-with-hooks rules. Predicate: track when rule has
  `animations`, `on_enter`, **`transitions`**, or **`on_change`**
  populated. Non-animated → `:no_match` (cross-binding interference
  rationale stands unchanged).
- [ ] Implement `diff_paths/3` in Engine:
  ```elixir
  # Returns [{path, old_val, new_val}, ...] for paths declared in
  # `transitions` or `on_change` whose resolved value changed.
  defp diff_paths(prev_instructions, curr_instructions, paths)
  ```
  where `paths = MapSet.union(transitions_paths, on_change_paths)`.
  Uses `get_in/2` with the path list.
- [ ] Implement `install_property_transitions/4`:
  ```elixir
  # For each {path, old, new} where transitions has a spec:
  # build a synthetic %Keyframes{} with two stops:
  #   [{0, nest(path, old)}, {100, nest(path, new)}]
  # iterations: 1, direction: :normal,
  # easing/duration from spec.
  # Skip if old is nil (CSS semantics: no transition on first paint).
  defp install_property_transitions(device_id, control_id, rule, diffs)
  ```
  `nest/2` walks the path list to build a nested map at the leaf:
  `nest([:fill, :amount], 73)` → `%{fill: %{amount: 73}}`.
  Dispatched via `Ticker.start_animation/5` with `kind: :one_shot`.
- [ ] Implement `install_property_on_change/4`:
  ```elixir
  # For each {path, _old, new} where on_change has a keyframe:
  # fire it as a one_shot. Fires regardless of old==nil (a property
  # appearing for the first time IS a change).
  defp install_property_on_change(device_id, control_id, rule, diffs)
  ```
  Note: on-change keyframes use the rule's resolved instructions as
  base (already passed via `Ticker.start_animation`'s `base` arg).
- [ ] Extend `apply_match_transition/4` same-idx branch:
  ```elixir
  # Refresh continuous (current behavior) AND diff old vs new
  # instructions, fire transitions + on_change for changed props.
  defp apply_match_transition(
    device_id, control_id,
    {:matched, prev_idx, prev_instructions},
    {:match, idx, rule, instructions}
  ) when prev_idx == idx do
    refresh_continuous(device_id, control_id, rule, instructions)
    diffs = diff_paths(prev_instructions, instructions,
                        relevant_paths(rule))
    install_property_transitions(device_id, control_id, rule, diffs)
    install_property_on_change(device_id, control_id, rule, diffs)
  end
  ```
- [ ] Update the no-op fast-path: skip refresh + diff only when rule
  has none of `animations`, `transitions`, `on_change`.
  (`on_enter` is rule-transition-only and doesn't contribute here.)
- [ ] Update `dispatch_binding/4` to pass current `instructions` into
  the new `last_match` shape via `match_summary/1`.
- [ ] Update `:no_match → match` and `match → match (diff idx)`
  branches to NOT fire `on_change` (CSS semantics: only same-idx
  re-matches with property diffs trigger on_change). The on_enter
  one-shot already covers rule-entry effects.

### Phase 4 — Path-key collision audit (parser correctness)

- [ ] Sanity-check the leaf-detection logic with adversarial inputs:
  - `transitions: { fill: { amount: { duration_ms: 100, easing: ease } } }`
    must parse as `%{[:fill, :amount] => spec}`, not
    `%{[:fill] => %{amount: ...}}`.
  - `transitions: { color: { duration_ms: 100 } }` must parse as
    `%{[:color] => spec}` (top-level prop).
  - `transitions: { fill: { duration_ms: 100 } }` is **ambiguous** —
    is `:fill` the leaf or is `:duration_ms` a phantom prop name?
    Decision: `:duration_ms` is a reserved leaf marker. Document
    this in `parse_transitions/2`'s docstring; raise if we see a
    nested map that has both `:duration_ms` AND another atom key
    that doesn't look like easing config.
- [ ] Add a YAML parser test asserting the ambiguous case raises a
  helpful `ArgumentError`.

### Phase 5 — Tests

YAML parser tests (in `test/loupey/bindings/yaml_parser_test.exs`,
adding to the existing `describe "parse_binding/2 — animation hooks"`):

- [ ] `[testing]` Top-level transition parses to
  `%{[:color] => %TransitionSpec{duration_ms: 300}}`.
- [ ] `[testing]` Nested transition (`fill.amount`) parses to
  `%{[:fill, :amount] => %TransitionSpec{...}}`.
- [ ] `[testing]` Multiple transitions (top-level + nested) coexist.
- [ ] `[testing]` `on_change` with nested path + inline keyframe parses
  to `%{[:fill, :amount] => %Keyframes{}}`.
- [ ] `[testing]` `on_change` with `effect: ripple` shorthand parses
  via `Effects.from_map/2`.
- [ ] `[testing]` Ambiguous `duration_ms` mixed with non-spec keys
  raises a descriptive `ArgumentError`.
- [ ] `[testing]` Missing `duration_ms` in a transition leaf raises.
- [ ] `[testing]` Round-trip through `@atom_map` keeps all keys atom
  (drift-guard, mirrors existing test).

Engine tests (in
`test/loupey/bindings/engine_animation_test.exs`, new describes):

- [ ] `[testing]` `describe "match → match same idx — transitions"`:
  - Two state changes that flip the resolved `color` value. Assert
    Ticker receives a `:one_shot` whose keyframe has two stops with
    the old and new color values. Continuous animation list unchanged.
  - Property unchanged → no transition installed.
  - First match (`:no_match → match`) — transition NOT fired.
  - Different rule_idx → transition NOT fired (rule-level cancel +
    install path runs, no per-property diff).
- [ ] `[testing]` `describe "match → match same idx — on_change"`:
  - Two state changes flipping `[:fill, :amount]`. Assert Ticker
    receives a `:one_shot` whose keyframe is the on_change keyframe
    from the rule. Refire on subsequent change.
  - Property unchanged → no on_change fired.
  - First match → on_change NOT fired.
- [ ] `[testing]` `describe "transitions + on_change combined"`:
  - One rule declaring both for the same property. State change
    fires both one-shots in the same dispatch.
- [ ] `[testing]` `describe "nil → val (property appears)"`:
  - Transition skipped (no old value to lerp).
  - on_change fired (property change includes "appears").
- [ ] `[testing]` `describe "last_match shape carries instructions"`:
  - After dispatch, `state.last_match[{control_id, 0}]` contains the
    resolved instructions in the third tuple element.
- [ ] `[testing]` Update existing tests that assert
  `last_match == %{... => {:matched, idx}}` to the new
  `{:matched, idx, instructions}` shape (or a wildcard pattern that
  ignores the third element where unrelated to the assertion).

### Phase 6 — Smoke YAML + docs

- [ ] Update `priv/blueprints/animated_examples.yaml` to include a new
  example exercising transitions + on_change. Pattern after Case 2
  + Case 5 from the v1 interview, but rendered in nested form:
  ```yaml
  - when: 'state == "on"'
    color: "#FFD700"
    fill:
      amount: '{{ attributes.brightness_pct or 0 }}'
      direction: to_top
    transitions:
      color: { duration_ms: 300, easing: ease_out }
      fill:
        amount: { duration_ms: 200, easing: ease_out }
    on_change:
      fill:
        amount:
          effect: ripple
          duration_ms: 400
          easing: ease_out
          color: "#FFFFFF80"
  ```
- [ ] Verify the updated YAML parses through the existing blueprint
  smoke test (already runs as part of the test suite).
- [ ] Update `guides/architecture.md` Animation Pipeline section: add
  one short paragraph explaining the diff dispatcher and where it
  fires (same-rule re-match only).
- [ ] Update `OutputRule` moduledoc: remove "ship in v2" note, replace
  with a 2-line description of the diff semantics.
- [ ] Write `progress.md` recording what landed (mirror v1 format).
- [ ] Write `scratchpad.md` capturing decisions + dead-ends from
  implementation.

### Phase 7 — Verify

- [ ] `mix format --check-formatted`
- [ ] `mix compile --warnings-as-errors`
- [ ] `mix test` (full suite, ensure 355 → 365+ passing, 0 failures)
- [ ] `mix credo --strict` (no new findings)
- [ ] `mix dialyzer` (no new warnings; expect new `TransitionSpec`
  type to introduce zero issues if specs are tight)

## Risks

**Q1: Can a same-rule re-match fire on_change AND a rule-level
on_enter at the same time?**
Only if the rule entered for the first time *this dispatch*, which
means `prev` was `:no_match` — and we route that through the
`:no_match → match` branch where on_enter fires but on_change does
not. Same-idx-same-idx never fires on_enter. No double-fire.

**Q2: Do transitions interact with continuous animations correctly?**
Yes — both end up as `one_shots` / `continuous` lists on the same
`ControlAnims`, deep-merged in stack order. Transition's per-property
override wins over continuous's per-property override at the same path
(later one_shots merge last in `process_control/2`). Authors who
declare a `color` transition AND a `color` continuous are asking for a
visual conflict; the transition's 300ms tween wins until completion,
then continuous continues from base. Acceptable behavior.

**Q3: Does the new `last_match` shape break existing call sites?**
Only the engine_animation_test assertions. Tests are part of this
plan; production callers all flow through `match_summary/1`.

## Verification at completion

A v2 dispatch is "done" when:
1. A blueprint with `transitions: {color: {duration_ms: 300}}` plus
   two state flips renders a smooth color tween on hardware.
2. A blueprint with `on_change: {[:fill, :amount]: ripple}` plus a
   brightness change renders a ripple overlay on the affected control.
3. The full test suite passes; engine_animation_test grows by ≥6
   tests covering the diff branches.
4. `mix credo --strict` and `mix dialyzer` clean.
5. `progress.md` lists all v2 deferrals from v1 that are now closed
   (`transitions`, `on_change`, compound keys decision).

## Self-check (deep)

- **Could a Ticker restart drop in-flight transitions?** Yes — same
  as v1 continuous. The Ticker monitor in Engine clears `last_match`
  on `:DOWN`, so the next state change triggers `:no_match → match`,
  which doesn't fire transitions or on_change (correct: we lost the
  prev value, can't lerp). Brief animation loss on Ticker crash is
  acceptable, matches v1 behavior.

- **What if `transitions` is declared on a property the rule never
  emits?** Diff sees `nil → nil` (or `nil → still_nil` over time).
  No fire, no error. Authoring noise but not a correctness bug.

- **What if a transition fires while a previous transition for the
  same property is still in-flight?** Two `:one_shot` flights stack
  in `ctl.one_shots`. The newer one was added later, so its frame
  merges last → wins for the property. Visual: instant re-tween from
  current visible value... wait, actually NO — the new keyframe's
  0% stop is the *previous resolved value*, not the *currently
  rendered value*. So if a 300ms color transition is 50% done
  (showing midpoint), and a new transition fires from that midpoint
  to a third color, the new keyframe's 0% would be the *second*
  color, not the midpoint, causing a visual snap.
  
  Mitigation for v2: cancel any in-flight one-shot at the same path
  before installing a new transition. Add `Ticker.cancel_at_path/3`
  or pre-filter `one_shots` by frame-key intersection. Track this as
  a Phase 3 concrete sub-task.

- [ ] `[architecture]` Add `Ticker.cancel_property_transitions/3`
  (or equivalent) so re-fired transitions don't stack mid-flight.
  Implementation: filter `ctl.one_shots` removing flights whose
  keyframe's stops touch the given path. Engine calls this before
  `install_property_transitions/4`.

  Alternative considered + rejected: tag synthetic transition
  flights with a `:property_path` field on `InFlight`. Cleaner but
  requires a schema change to `InFlight` for a v2-only optimization.
  Filter-by-stops keeps the InFlight schema unchanged.

  Add a test in Phase 5 covering: two rapid same-property
  transitions only run the second one (older flight cancelled).
