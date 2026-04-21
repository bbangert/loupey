defmodule Loupey.Repo.Migrations.UniqueActiveProfilePerDeviceType do
  use Ecto.Migration

  # At most one `active: true` profile per `device_type` at any time.
  #
  # The invariant is enforced in application code by `Loupey.Orchestrator`
  # (activation goes through a single GenServer + `Profiles.activate_exclusive/1`
  # in a transaction). This partial unique index is defense-in-depth — if
  # anything ever bypasses the Orchestrator (a manual DB fix-up, a background
  # worker, a future multi-node deployment), the DB constraint prevents
  # silently corrupting state. `Profile.changeset/2` maps the constraint name
  # to a changeset error so violations surface as `{:error, changeset}`
  # rather than a raised `Ecto.ConstraintError`.
  #
  # `where: "active = 1"` rather than `"active = true"`: `ecto_sqlite3` stores
  # booleans as integers, and `= 1` is the portable partial-index predicate
  # across SQLite versions.
  def change do
    create(
      unique_index(:profiles, [:device_type],
        where: "active = 1",
        name: :profiles_one_active_per_device_type
      )
    )
  end
end
