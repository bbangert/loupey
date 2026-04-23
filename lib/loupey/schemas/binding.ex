defmodule Loupey.Schemas.Binding do
  @moduledoc """
  Persisted binding within a layout.

  The binding's rules are stored as YAML text in the `yaml` field.
  On load, the YAML is parsed into the core `Loupey.Bindings.Binding` struct.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Loupey.Bindings.YamlParser
  alias Loupey.Schemas.Layout

  schema "bindings" do
    field(:control_id, :string)
    field(:entity_id, :string)
    field(:yaml, :string)

    belongs_to(:layout, Layout)

    timestamps()
  end

  # Control-id strings are either bracketed-tuple (`"{:key, 3}"`,
  # `"{:button, 0}"`) or bare atom-name (`"left_strip"`, `"knob_tl"`) —
  # matching exactly what `DeviceGrid.format_control_id/1` emits. Anything
  # else is a DB-corruption red flag — reject at changeset time.
  @control_id_format ~r/^(\{:\w+, \d+\}|\w+)$/

  # HA entity IDs always look like `domain.object_id`, lowercase snake_case.
  @entity_id_format ~r/^[a-z_]+\.[a-z0-9_]+$/

  def changeset(binding, attrs) do
    binding
    |> cast(attrs, [:control_id, :entity_id, :yaml, :layout_id])
    |> validate_required([:control_id, :yaml, :layout_id])
    |> validate_format(:control_id, @control_id_format)
    |> validate_format(:entity_id, @entity_id_format)
  end

  @doc """
  Parse the YAML field into a core Binding struct.
  """
  def to_core(%__MODULE__{yaml: yaml, entity_id: entity_id}) do
    case YamlParser.parse_binding(yaml) do
      {:ok, binding} -> {:ok, %{binding | entity_id: entity_id || binding.entity_id}}
      error -> error
    end
  end
end
