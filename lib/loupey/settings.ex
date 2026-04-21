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

  def save_ha_config(attrs) do
    case get_active_ha_config() do
      nil -> create_ha_config(Map.put(attrs, "active", true))
      config -> update_ha_config(config, attrs)
    end
  end

  def delete_ha_config(%HAConfig{} = config), do: Repo.delete(config)
end
