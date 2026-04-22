# Scratchpad: yaml-parser-atom-safety

## Dead Ends (DO NOT RETRY)

(none yet)

## Decisions

- **2026-04-21: Plan superseded by minimal-touch fix.** Full whitelist-walker (option b) was over-scoped for Loupey's current threat model. YAML is author-authored for a single user controlling their own devices — no remote ingest, no shared-blueprint import, no multi-tenancy. An attacker able to write YAML already owns the box. Shipped a 3-site `String.to_atom` → `safe_atom/1` (`to_existing_atom` with `rescue ArgumentError -> str`) swap plus a bounded-atom rewrite of the `@known_atoms` list (`~w()a` at compile time). Unknown keys/triggers stay as strings; downstream pattern-matches naturally ignore them. Two regression tests (`:erlang.system_info(:atom_count)` deltas) guard the behavior. Implemented directly — remaining plan tasks are abandoned.
- **Revisit this plan if/when:** a shared-blueprints import feature, a public/remote YAML ingest endpoint, or any multi-tenant path lands. The full whitelist walker becomes necessary at that point.
- **Historical (now stale) strategy:** whitelist-atomize keys at parse time (option b from triage); drop + log unknown keys. Kept for reference if the plan is revived.

## Open Questions

- Full `@atomizable_keys` list — must be built by auditing every `%{...}` pattern on YAML-sourced trees. Record here as discovered during implementation.
- `parse_trigger/1` unknown-trigger shape: `:unknown` atom vs string? Check `Bindings.Rules.matches?/2` to see which it already tolerates.

## References

- Source triage: `.claude/plans/streamdeck-driver/reviews/loupey-triage.md` (Plan 3)
- Original review: `.claude/plans/streamdeck-driver/reviews/loupey-review.md` (BLOCKER #2)
- Working whitelist pattern: `lib/loupey/profiles.ex:195-202`
- Related Plan 5 cleanup: `engine.ex:283-291` dual atom/string `Map.get` — fixing the upstream invariant here clears that finding.
