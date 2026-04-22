defmodule Loupey.Settings do
  @moduledoc """
  Context for managing application settings, including HA connection config.
  """

  import Ecto.Query

  alias Loupey.Repo
  alias Loupey.Schemas.HAConfig

  def get_active_ha_config do
    Repo.one(from(c in HAConfig, where: c.active == true, limit: 1))
  end

  def get_ha_config(id), do: Repo.get(HAConfig, id)

  def create_ha_config(attrs) do
    %HAConfig{}
    |> HAConfig.changeset(attrs)
    |> Repo.insert()
  end

  def update_ha_config(%HAConfig{} = config, attrs) do
    config
    |> HAConfig.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Upsert an HA config by name. If no `name` is supplied, the schema default
  (`"default"`) is used. Replaces the previous two-query "fetch active,
  then update-or-insert" dance with a single round-trip via SQLite's
  `ON CONFLICT` clause.
  """
  def save_ha_config(attrs) do
    %HAConfig{}
    |> HAConfig.changeset(Map.put_new(attrs, "active", true))
    |> Repo.insert(
      on_conflict: {:replace, [:url, :token, :active, :updated_at]},
      conflict_target: [:name]
    )
  end

  def delete_ha_config(%HAConfig{} = config), do: Repo.delete(config)
end
