# Scratchpad: safe-expression-evaluator

## Dead Ends (DO NOT RETRY)

(none yet)

## Decisions

- **Approach**: handwritten whitelisted AST walker — user-confirmed in triage. NOT Abacus, NOT recursive-descent.
- **Parser**: `Code.string_to_quoted/1`. Safe (returns AST, doesn't evaluate).
- **Unknown AST** → reject. Reject-by-default is the point; the walker must pattern-match every allowed shape explicitly.
- **Error model**: structured tuples (`{:error, {:disallowed_call, mfa}}`, etc.) — lets callers log with context.
- **2026-04-21: User re-confirmed Option B (full plan) driven primarily by LATENCY, not security.** That reshapes the architecture — parse-once-eval-many is the real win. Lazy memoize on `InputRule`/`OutputRule` structs keeps the diff focused vs. eager parse at YAML-load time.
- **2026-04-21: Backward compat** — `Expression` module stays as a thin wrapper around `Evaluator`. Zero caller diff.
- **2026-04-21: Drop the `rewrite_function_calls/1` hack** — our walker recognizes `state_of(…)`, `attr_of(…)`, `round(…)` as local calls directly from the AST shape `{:state_of, _, args}`. No more string pre-processing.

## Grammar inventory (from Phase 1 grep of priv/blueprints/, test/fixtures/bindings/, test/**/*_test.exs)

### Variables in scope

From `Loupey.Bindings.Expression.build_bindings/1` + `resolve_with_context/3`:
- `state` (entity state string, nullable)
- `attributes` (entity attributes map)
- `entity_id` (entity ID string)
- Event context (touch/strip): `touch_x`, `touch_y`, `touch_id`, `control_id`, `strip_width`, `strip_height`, `control_width`, `control_height`

(`inputs.*` is resolved via string substitution BEFORE expressions evaluate — not the evaluator's concern.)

### Local calls in use

- `state_of/1` — `state_of("light.foo")`
- `attr_of/2` — `attr_of("light.foo", "brightness")`
- `round/1` — `round((1 - touch_y / strip_height) * 255)`

Nothing else. No other Kernel calls anywhere.

### Operators in use

- Comparison: `==`, `!=` (observed; `>`, `<`, `>=`, `<=` included by spec)
- Arithmetic: `-` (unary + binary), `*`, `/` (observed; `+` included by spec)
- Logical: `||` (short-circuit default: `attributes["brightness"] || 0`)
- Access: `map["key"]` → desugars to `Access.get/2`

### Literals in use

- Integer, float, string, boolean (`true`/`false`)
- `nil` not explicitly seen but standard
- **No atom literals anywhere** — every identifier is a variable or call

### NOT used anywhere

- Module-qualified calls (`File.*`, `Kernel.*`, etc.) → reject
- Anonymous fns (`fn -> end`) → reject
- Captures (`&Mod.fun/1`) → reject
- Pipes (`|>`) → reject
- `apply/2-3` → reject
- `__ENV__`, `__MODULE__`, `__CALLER__`, `__STACKTRACE__` → reject
- `and`/`or`/`not` keywords → reject (use `||`)
- `in` operator → reject
- Atom literals (`:foo`) → reject
- Module attrs (`@foo`) → reject
- Aliases → reject
- `try`/`receive`/`case`/`if`/`cond` → reject

## Normalized AST shape (our internal form post-`normalize/1`)

```
{:lit, term}                        # integer | float | binary | boolean | nil
{:var, atom_name}                   # looked up in ctx; undefined → nil
{:call, :state_of, [arg_ast]}
{:call, :attr_of, [arg1_ast, arg2_ast]}
{:call, :round, [arg_ast]}
{:op, op_atom, [left_ast, right_ast]}  # == != > < >= <= + - * / ||
{:neg, arg_ast}                     # unary -
{:access, map_ast, key_ast}         # map[key] → Access.get/2
```

Anything else from `Code.string_to_quoted/1` → `{:error, {:disallowed, …}}` at parse time.

## Public API

- `Evaluator.parse(source)` → `{:ok, ast} | {:error, reason}`
- `Evaluator.eval(ast, context)` → `{:ok, term} | {:error, reason}`
- `Evaluator.evaluate(source, context)` → `{:ok, term} | {:error, reason}` (parse + eval; for callers that can't cache)

## Caching strategy

**Final shipped design: per-process dictionary memoization in `Evaluator.evaluate/2`.**

- Rejected "lazy memoize on structs" because Elixir structs are immutable — memoization requires the caller to thread the updated struct through, and most callers don't (e.g. `Rules.matches?/2` just returns a bool).
- Rejected "eager parse at YAML-load time (pivot decision noted earlier)" because it couples YamlParser to the Evaluator and requires changes to `InputRule`/`OutputRule` struct contracts + all their downstream readers.
- **Shipped**: `Evaluator.evaluate/2` checks `Process.get({__MODULE__, source})` before parsing. First call per process per source: parse + cache. Subsequent calls: cache hit, skip parse+normalize entirely.
- **Why it works**: the binding engine is a long-lived GenServer (one per active binding set); the same expression strings fire repeatedly as HA state changes. Process dict scopes cache to the engine pid; auto-cleanup on process exit; no global state, no lock contention.
- **Parse errors not cached** — a source edited in the UI gets a fresh parse on the next evaluation.

## Benchmark (2026-04-21)

Per-call timing on `round((attributes["brightness"] || 0) / 255 * 100)`,
100_000 iterations, in-project `mix run` on bare-metal Fedora:

| Path | µs/op | vs old |
|---|---|---|
| `Code.eval_string/2` (old) | 241 | 1× |
| `Evaluator.evaluate` cold (no cache) | 154 | 1.6× |
| `Evaluator.evaluate` warm (proc-dict cache) | **0.142** | **1695×** |
| `Evaluator.eval(ast)` direct | 0.18 | 1341× |

The latency goal is solidly delivered. Warm-path per-expression cost drops
from 241 µs to 0.14 µs.

## Follow-ups not in this plan

- `Code.string_to_quoted/1` uses default options, which creates atoms for
  unknown identifiers. For Loupey's single-user threat model this is fine;
  if the blueprint-sharing surface ever lands, tighten with
  `existing_atoms_only: true` + a compile-time atom-interning module attribute.
- `Expression.extract_entity_refs/1` still uses regex scanning instead of
  walking the AST. Works correctly but diverges from the rest of the module;
  consider moving to AST-walk for consistency if a benchmark ever shows it
  matters (currently fires per-YAML-load, not per-render).

## Error model

- Parse errors: `{:error, {:parse, reason}}` where reason is the original `Code.string_to_quoted` error or `{:disallowed, ast_shape}` for whitelist misses.
- Eval errors: `{:error, {:eval, message}}` — caught from ArithmeticError / MatchError etc. during walk.
- Backward-compat: `Expression.eval/2` converts `{:error, _}` to `nil` (matches current behavior).

## Open Questions

- Should `Evaluator.parse/1` fail hard or soft on unknown shapes? **Hard** — that's the security contract. Soft-fail defeats the purpose.
- Division by zero: let it bubble up as `{:error, {:eval, ...}}`. Expression wrapper converts to `nil` for backward compat.
- Short-circuit `||` MUST NOT evaluate RHS if LHS is truthy. Walker needs to handle `||` and `&&` specially (not as plain binary op).

## References

- Source triage: `.claude/plans/streamdeck-driver/reviews/loupey-triage.md` (Plan 4)
- Original review: `.claude/plans/streamdeck-driver/reviews/loupey-review.md` (BLOCKER #1)
- Security review: `.claude/plans/streamdeck-driver/reviews/security-review.md`
- Current evaluator: `lib/loupey/bindings/expression.ex`
- Callers: `lib/loupey/bindings/rules.ex:84,95,132,140,146`, `lib/loupey/bindings/engine.ex:348,359`, `lib/loupey/bindings/layout_engine.ex:122,131,139`
