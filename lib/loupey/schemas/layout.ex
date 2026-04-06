defmodule Loupey.Schemas.Layout do
  @moduledoc """
  Persisted layout within a profile.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Loupey.Schemas.{Binding, Profile}

  schema "layouts" do
    field :name, :string
    field :position, :integer, default: 0

    belongs_to :profile, Profile
    has_many :bindings, Binding

    timestamps()
  end

  def changeset(layout, attrs) do
    layout
    |> cast(attrs, [:name, :position, :profile_id])
    |> validate_required([:name, :profile_id])
  end
end
