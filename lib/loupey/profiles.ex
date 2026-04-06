defmodule Loupey.Profiles do
  @moduledoc """
  Context for managing device profiles, layouts, and bindings.
  """

  import Ecto.Query

  alias Loupey.Repo
  alias Loupey.Schemas.{Binding, Layout, Profile}

  # -- Profiles --

  def list_profiles do
    Repo.all(from p in Profile, order_by: [desc: p.updated_at])
  end

  def get_profile(id) do
    Profile
    |> Repo.get(id)
    |> Repo.preload(layouts: [bindings: []])
  end

  def get_active_profile do
    Profile
    |> where(active: true)
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
        bindings =
          layout.bindings
          |> Enum.group_by(& &1.control_id)
          |> Map.new(fn {control_id_str, schema_bindings} ->
            control_id = parse_control_id(control_id_str)

            core_bindings =
              Enum.flat_map(schema_bindings, fn sb ->
                case Loupey.Schemas.Binding.to_core(sb) do
                  {:ok, b} -> [b]
                  _ -> []
                end
              end)

            {control_id, core_bindings}
          end)

        {layout.name,
         %Loupey.Bindings.Layout{
           name: layout.name,
           bindings: bindings
         }}
      end)

    %Loupey.Bindings.Profile{
      name: profile.name,
      device_type: profile.device_type,
      active_layout: profile.active_layout || Map.keys(layouts) |> List.first(),
      layouts: layouts
    }
  end

  # Parse control_id strings back to the atom/tuple form used internally
  defp parse_control_id(str) do
    case Regex.run(~r/^\{:(\w+), (\d+)\}$/, str) do
      [_, type, num] -> {String.to_atom(type), String.to_integer(num)}
      _ -> String.to_atom(str)
    end
  end
end
