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
    |> validate_yaml_parses()
  end

  # Prevention layer: reject malformed YAML at save time so the editor
  # surfaces the parse error to the author instead of letting bad rows
  # land in the DB. The atomization, animation parsing, and effect
  # resolution paths all *raise* on bad input rather than returning
  # tagged tuples, so a try/rescue is required — we cannot rely solely
  # on `parse_binding/1`'s `{:error, _}` return.
  #
  # `get_field/2` (rather than `get_change/2`) returns the current
  # value whether or not `:yaml` is being changed, so a row with
  # pre-existing bad YAML can't be updated through the changeset for
  # any field without first fixing the YAML. That closes the
  # silent-data-rot path where editing `entity_id` on a broken
  # binding would silently leave the bad YAML in place.
  defp validate_yaml_parses(changeset) do
    case get_field(changeset, :yaml) do
      nil ->
        changeset

      yaml when is_binary(yaml) ->
        try do
          case YamlParser.parse_binding(yaml) do
            {:ok, _} ->
              changeset

            {:error, reason} ->
              add_error(changeset, :yaml, "could not be parsed: #{inspect(reason)}")
          end
        rescue
          e -> add_error(changeset, :yaml, "could not be parsed: #{Exception.message(e)}")
        end
    end
  end

  @doc """
  Parse the YAML field into a core Binding struct.

  Returns `{:error, {:parse_failed, message}}` rather than raising on
  malformed YAML so one bad binding cannot crash profile load — the
  engine skips it via `Profiles.convert_binding/1`'s flat_map
  fallthrough. The `validate_yaml_parses/1` changeset step prevents
  most bad rows from being written; this is the runtime safety net
  for rows that slipped in before the validation existed.
  """
  def to_core(%__MODULE__{yaml: yaml, entity_id: entity_id}) do
    case YamlParser.parse_binding(yaml) do
      {:ok, binding} -> {:ok, %{binding | entity_id: entity_id || binding.entity_id}}
      {:error, _} = error -> error
    end
  rescue
    e -> {:error, {:parse_failed, Exception.message(e)}}
  end
end
