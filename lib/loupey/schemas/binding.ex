defmodule Loupey.Schemas.Binding do
  @moduledoc """
  Persisted binding within a layout.

  The binding's rules are stored as YAML text in the `yaml` field.
  On load, the YAML is parsed into the core `Loupey.Bindings.Binding` struct.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Loupey.Schemas.Layout

  schema "bindings" do
    field :control_id, :string
    field :entity_id, :string
    field :yaml, :string

    belongs_to :layout, Layout

    timestamps()
  end

  def changeset(binding, attrs) do
    binding
    |> cast(attrs, [:control_id, :entity_id, :yaml, :layout_id])
    |> validate_required([:control_id, :yaml, :layout_id])
  end

  @doc """
  Parse the YAML field into a core Binding struct.
  """
  def to_core(%__MODULE__{yaml: yaml, entity_id: entity_id}) do
    case Loupey.Bindings.YamlParser.parse_binding(yaml) do
      {:ok, binding} -> {:ok, %{binding | entity_id: entity_id || binding.entity_id}}
      error -> error
    end
  end
end
