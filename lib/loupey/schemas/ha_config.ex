defmodule Loupey.Schemas.HAConfig do
  @moduledoc """
  Persisted Home Assistant connection configuration.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "ha_configs" do
    field(:url, :string)
    field(:token, :string)
    field(:name, :string, default: "default")
    field(:active, :boolean, default: true)

    timestamps()
  end

  def changeset(config, attrs) do
    config
    |> cast(attrs, [:url, :token, :name, :active])
    |> validate_required([:url, :token])
  end

  @doc """
  Convert to the core Config struct used by the HA connection.
  """
  def to_core(%__MODULE__{url: url, token: token}) do
    %Hassock.Config{url: url, token: token}
  end
end
