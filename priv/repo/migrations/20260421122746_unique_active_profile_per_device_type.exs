defmodule Loupey.Repo.Migrations.UniqueActiveProfilePerDeviceType do
  use Ecto.Migration

  # At most one `active: true` profile per `device_type` at any time.
  #
  # The invariant is enforced in application code by `Loupey.Orchestrator`
  # (activation goes through a single GenServer + `Profiles.activate_exclusive/1`
  # in a transaction). This partial unique index is defense-in-depth — if
  # anything ever bypasses the Orchestrator (a manual DB fix-up, a background
  # worker, a future multi-node deployment), the constraint surfaces as a
  # changeset error rather than silently corrupting state.
  def change do
    create(
      unique_index(:profiles, [:device_type],
        where: "active = true",
        name: :profiles_one_active_per_device_type
      )
    )
  end
end
