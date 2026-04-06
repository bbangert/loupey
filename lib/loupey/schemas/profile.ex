defmodule Loupey.Schemas.Profile do
  @moduledoc """
  Persisted device profile containing layouts.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Loupey.Schemas.Layout

  schema "profiles" do
    field :name, :string
    field :device_type, :string
    field :active_layout, :string
    field :active, :boolean, default: false

    has_many :layouts, Layout

    timestamps()
  end

  def changeset(profile, attrs) do
    profile
    |> cast(attrs, [:name, :device_type, :active_layout, :active])
    |> validate_required([:name, :device_type])
  end
end
