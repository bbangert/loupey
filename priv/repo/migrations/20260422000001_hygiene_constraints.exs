defmodule Loupey.Repo.Migrations.HygieneConstraints do
  use Ecto.Migration

  @moduledoc """
  Phase 3 of the loupey-hygiene-sweep plan: add the missing DB-level
  correctness guards.

  - `ha_configs.name` had no uniqueness constraint — the settings-upsert
    path (`save_ha_config/1`) relies on `ON CONFLICT (name)` post this
    change.
  - `layouts.(profile_id, position)` had no uniqueness constraint — two
    layouts on the same profile could share a position, which the
    profile-editor UI orders by.

  The plan also asked for `NOT NULL` on `profiles.active` and
  `ha_configs.active`. Intentionally NOT included here: SQLite doesn't
  support `ALTER COLUMN` and ecto_sqlite3's `modify` doesn't auto-route
  through a table rebuild. The rebuild pattern (create new table, copy,
  drop, rename, recreate indexes) has meaningful error surface for a
  defense-in-depth change on a field that already has `default:` at the
  Ecto schema level AND at the original migration's column definition
  — not worth the complexity for this codebase's threat shape. Revisit
  if a real nil-`active` bug ever surfaces.

  Verified ahead of writing this migration that the dev DB has no existing
  rows that would violate the unique constraints above.
  """

  def change do
    create(unique_index(:ha_configs, [:name]))
    create(unique_index(:layouts, [:profile_id, :position]))
  end
end
