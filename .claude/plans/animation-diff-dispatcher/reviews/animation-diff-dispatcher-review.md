# Review — animation-diff-dispatcher

**Verdict: PASS WITH WARNINGS**

3 WARNINGs (1 actionable coverage gap, 1 actionable assertion gap,
1 future-bug-prevention refactor); 5 SUGGESTIONs (stylistic /
defensive coverage); 1 PRE-EXISTING flagged for awareness only.

Files reviewed (the v2 diff):
`lib/loupey/animation/transition_spec.ex` (NEW),
`lib/loupey/animation/ticker.ex`,
`lib/loupey/bindings/engine.ex`,
`lib/loupey/bindings/output_rule.ex`,
`lib/loupey/bindings/yaml_parser.ex`,
`test/loupey/bindings/engine_animation_test.exs`,
`test/loupey/bindings/yaml_parser_test.exs`,
`priv/blueprints/animated_examples.yaml`,
`guides/architecture.md`.

Specialists run: elixir-reviewer, security-analyzer,
testing-reviewer, verification-runner (file-write denied —
verification re-run directly; results below).

## Verification (fallback re-run)

| Check | Status |
|---|---|
| `mix format --check-formatted` | PASS |
| `mix compile --warnings-as-errors` | PASS |
| `mix test` | PASS (389 / 0 failures, 20 excluded) |
| `mix credo --strict` | PASS (1181 mods/funs, 0 issues) |
| `mix dialyzer` | PASS (11 errors, all in existing skip list) |

## Findings

### WARNING — same-idx clause guard duplicates `rule_animated?/1`

`lib/loupey/bindings/engine.ex:495-507`. The clause head pattern
matches `animations: []` and guards `map_size(t) == 0 and map_size(c) == 0`
separately from `rule_animated?/1`'s definition. The
"keep in sync" comment I added flags the duplication, but nothing
enforces it at compile time. A future hook field added to
`OutputRule` updated only in `rule_animated?/1` would cause same-idx
re-matches to silently skip the new hook.

Fix: replace both with a `defguardp`:

```elixir
defguardp rule_has_no_reactive_hooks(rule)
  when rule.animations == [] and
       map_size(rule.transitions) == 0 and
       map_size(rule.on_change) == 0

defp rule_animated?(rule), do: not rule_has_no_reactive_hooks(rule)

defp apply_match_transition(_did, _cid, {:matched, _, _}, {:match, _, rule, _})
     when rule_has_no_reactive_hooks(rule), do: :ok
```

### WARNING — combined transition+on_change test doesn't assert keyframe stops

`test/loupey/bindings/engine_animation_test.exs` (the
`describe "transitions + on_change combined for same property"`
test). Asserts `length(transitions) == 1` and
`property_path == [:fill, :amount]` but skips the keyframe stops
check that the standalone transition tests do. A bug emitting
wrong old/new values or wrong nesting in the combined path would
pass.

Fix: add `assert [{0, %{fill: %{amount: 30}}}, {100, %{fill: %{amount: 80}}}] = hd(transitions).keyframe.stops`.

### WARNING — plan's "Refire on subsequent change" test missing

`.claude/plans/animation-diff-dispatcher/plan.md:299` calls out a
test asserting `on_change` re-fires on the *third* dispatch
(30→80→40 sequence), not just the second. Currently only the
30→80 fire is exercised. The dispatcher logic supports re-fire
(synthetic flight installation is per-diff), but coverage is
absent.

Fix: extend the existing on_change "fires on diff" test or add a
sibling test that does three dispatches and asserts two
`one_shots` accumulate (or one + completion).

### SUGGESTION — `walk_transitions/2` cond wants function heads

`lib/loupey/bindings/yaml_parser.ex:271-283`. Three `cond` branches
differ only by `path` shape. `is_map_key/2` guards (Elixir ≥1.10)
would let pattern-matched function heads replace the cond. Same
applies to `walk_on_change/3`. Stylistic — current cond is correct
and readable.

### SUGGESTION — `if existing` over `Map.get` wants `case`

`lib/loupey/animation/ticker.ex:269` (in `install_animation/6`).
Implicit truthiness; `case Map.get(...)` with `nil`/binding heads
makes intent explicit. Stylistic.

### SUGGESTION — val → nil edge case unspecified

If a property disappears from instructions on a same-idx re-match,
`get_in(curr, path)` returns `nil`. `diff_paths/3` would emit
`{path, val, nil}`. The transition path's `nil → val` skip handles
old=nil; the `val → nil` direction is not explicitly handled in
either code or tests. Likely benign (lerp_value on nil endpoint
returns the non-nil side) but worth a single test or a
"val → nil ⇒ snap, not animate" doc line.

### SUGGESTION — 3+ segment property paths untested

Both YAML and engine tests reach at most `[:fill, :amount]` (2
segments). `walk_transitions`, `nest/2`, and `diff_paths` are all
recursion-driven and generic, but a single `[:fill, :gradient,
:stop_0]`-shaped test would guard against off-by-one bugs in the
flatten logic.

### SUGGESTION — `async: true` likely safe

`engine_animation_test.exs` runs `async: false`. Every
`setup_engine/1` uses `make_ref()` for unique device_ids, so tests
are already process-isolated. The `async: false` adds unnecessary
serialization. Low priority — not worth the churn unless suite
becomes slow.

### PRE-EXISTING — `cancel_all_animations/1` casts spurious cancels

`lib/loupey/bindings/engine.ex:540-546`. Iterates all
`last_match` keys without filtering on `{:matched, _, _}` —
non-animated entries (which collapse to `:no_match`) generate
no-op cancel casts. Pre-dates this diff; not introduced here. Worth
filtering when next touched: `Enum.flat_map(last_match, fn {{cid, _}, {:matched, _, _}} -> [cid]; _ -> [] end)`.

## Security

No findings. Audit notes: no `String.to_atom/1` on user input;
`get_in/2` paths can't traverse to structs (instructions are
plain atom-keyed maps); `__struct__` shape collision benign
(returns nil); shape pollution fails loud at parse time.

## Action Items

### Should Fix (Warnings)
- [ ] Refactor `apply_match_transition/4` clause-5 + `rule_animated?/1` to share a `defguardp` (engine.ex:495-507)
- [ ] Add keyframe-stops assertion to combined transition+on_change test (engine_animation_test.exs)
- [ ] Add "refire on subsequent change" test for on_change

### Consider (Suggestions)
- [ ] `walk_transitions`/`walk_on_change` cond → function heads
- [ ] Ticker `install_animation` `if existing` → `case`
- [ ] val → nil test or doc note
- [ ] 3+ segment path test
- [ ] Flip engine_animation_test to async: true

### Track for Future Cleanup (Pre-existing)
- [ ] `cancel_all_animations/1` should filter to `{:matched, _, _}` entries
