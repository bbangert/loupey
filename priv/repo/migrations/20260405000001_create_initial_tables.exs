defmodule Loupey.Repo.Migrations.CreateInitialTables do
  use Ecto.Migration

  def change do
    create table(:ha_configs) do
      add :url, :string, null: false
      add :token, :string, null: false
      add :name, :string, default: "default"
      add :active, :boolean, default: true

      timestamps()
    end

    create table(:profiles) do
      add :name, :string, null: false
      add :device_type, :string, null: false
      add :active_layout, :string
      add :active, :boolean, default: false

      timestamps()
    end

    create table(:layouts) do
      add :name, :string, null: false
      add :profile_id, references(:profiles, on_delete: :delete_all), null: false
      add :position, :integer, default: 0

      timestamps()
    end

    create index(:layouts, [:profile_id])

    create table(:bindings) do
      add :layout_id, references(:layouts, on_delete: :delete_all), null: false
      add :control_id, :string, null: false
      add :entity_id, :string
      add :yaml, :text, null: false

      timestamps()
    end

    create index(:bindings, [:layout_id])
    create index(:bindings, [:layout_id, :control_id])
  end
end
