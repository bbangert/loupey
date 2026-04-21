defmodule Loupey.Profiles do
  @moduledoc """
  Context for managing device profiles, layouts, and bindings.
  """

  import Ecto.Query

  alias Loupey.Repo
  alias Loupey.Schemas.{Binding, Layout, Profile}

  # -- Profiles --

  def list_profiles do
    Repo.all(from(p in Profile, order_by: [desc: p.updated_at]))
  end

  def get_profile(id) do
    Profile
    |> Repo.get(id)
    |> Repo.preload(layouts: [bindings: []])
  end

  @doc """
  Return every profile with `active: true`, one per device type. The
  uniqueness-per-device-type invariant is enforced by `Orchestrator` on
  activation (not at the database level).
  """
  def list_active_profiles do
    Profile
    |> where(active: true)
    |> Repo.all()
    |> Repo.preload(layouts: [bindings: []])
  end

  @doc """
  Return the single active profile for a given `device_type`, or `nil`.
  """
  def get_active_profile_for(device_type) do
    Profile
    |> where([p], p.active == true and p.device_type == ^device_type)
    |> limit(1)
    |> Repo.one()
    |> Repo.preload(layouts: [bindings: []])
  end

  def create_profile(attrs) do
    %Profile{}
    |> Profile.changeset(attrs)
    |> Repo.insert()
  end

  def update_profile(%Profile{} = profile, attrs) do
    profile
    |> Profile.changeset(attrs)
    |> Repo.update()
  end

  def delete_profile(%Profile{} = profile), do: Repo.delete(profile)

  # -- Layouts --

  def create_layout(attrs) do
    %Layout{}
    |> Layout.changeset(attrs)
    |> Repo.insert()
  end

  def update_layout(%Layout{} = layout, attrs) do
    layout
    |> Layout.changeset(attrs)
    |> Repo.update()
  end

  def delete_layout(%Layout{} = layout), do: Repo.delete(layout)

  # -- Bindings --

  def create_binding(attrs) do
    %Binding{}
    |> Binding.changeset(attrs)
    |> Repo.insert()
  end

  def update_binding(%Binding{} = binding, attrs) do
    binding
    |> Binding.changeset(attrs)
    |> Repo.update()
  end

  def delete_binding(%Binding{} = binding), do: Repo.delete(binding)

  # -- Conversion to core structs --

  @doc """
  Convert a persisted Profile (with preloaded layouts and bindings) into
  the core `Loupey.Bindings.Profile` struct used by the binding engine.
  """
  def to_core_profile(%Profile{} = profile) do
    layouts =
      Map.new(profile.layouts, fn layout ->
        {layout.name, convert_layout(layout)}
      end)

    %Loupey.Bindings.Profile{
      name: profile.name,
      device_type: profile.device_type,
      active_layout: profile.active_layout || Map.keys(layouts) |> List.first(),
      layouts: layouts
    }
  end

  defp convert_layout(layout) do
    bindings =
      layout.bindings
      |> Enum.group_by(& &1.control_id)
      |> Map.new(fn {control_id_str, schema_bindings} ->
        control_id = parse_control_id(control_id_str)
        core_bindings = Enum.flat_map(schema_bindings, &convert_binding/1)
        {control_id, core_bindings}
      end)

    %Loupey.Bindings.Layout{name: layout.name, bindings: bindings}
  end

  defp convert_binding(sb) do
    case Binding.to_core(sb) do
      {:ok, b} -> [b]
      _ -> []
    end
  end

  # Parse control_id strings back to the atom/tuple form used internally.
  # Uses `String.to_existing_atom/1` since all legitimate control_ids are
  # already defined by a variant's `device_spec/0`; a corrupted DB row
  # with an unknown atom name falls back to the raw string so downstream
  # `Spec.find_control/2` returns nil and the binding is gracefully skipped.
  defp parse_control_id(str) do
    case Regex.run(~r/^\{:(\w+), (\d+)\}$/, str) do
      [_, type, num] -> {String.to_existing_atom(type), String.to_integer(num)}
      _ -> String.to_existing_atom(str)
    end
  rescue
    ArgumentError -> str
  end
end
