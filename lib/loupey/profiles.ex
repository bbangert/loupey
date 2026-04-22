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
  Return every profile with `active: true`, with layouts + bindings
  preloaded.

  At most one active profile per device type is enforced at two levels:
  `Loupey.Orchestrator` goes through `activate_exclusive/1` in a
  transaction, and a partial unique index
  (`profiles_one_active_per_device_type`) on
  `(device_type) WHERE active = 1` guards against any bypass path.
  """
  def list_active_profiles do
    Profile
    |> where(active: true)
    |> Repo.all()
    |> Repo.preload(layouts: [bindings: []])
  end

  @doc """
  Lightweight variant of `list_active_profiles/0` for status displays and
  bulk operations that only need identity + device type. Skips the
  layouts/bindings preload, so it's safe to call frequently.
  """
  def list_active_profile_summaries do
    Profile
    |> where(active: true)
    |> select([p], %{id: p.id, name: p.name, device_type: p.device_type})
    |> Repo.all()
  end

  @doc """
  Return the single active profile for a given `device_type`, or `nil`.

  If multiple active profiles exist for the same device type (shouldn't
  happen under normal flow, but isn't enforced at the DB level), the most
  recently updated one wins so crash recovery is deterministic.
  """
  def get_active_profile_for(device_type) do
    Profile
    |> where([p], p.active == true and p.device_type == ^device_type)
    |> order_by([p], desc: p.updated_at, desc: p.inserted_at, desc: p.id)
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

  @doc """
  Flip a profile to `active: false`. Separate from `update_profile/2` so the
  Orchestrator can order DB update before engine teardown — stopping engines
  first and then failing the DB update leaves the system in a worse state
  (marked active but not running) than the inverse.
  """
  def deactivate(%Profile{} = profile) do
    profile
    |> Profile.changeset(%{"active" => false})
    |> Repo.update()
  end

  @doc """
  Atomically make `profile` the single active profile for its `device_type`.

  In one `Repo.transaction/1`:

  1. Sets `active: false` on every other row matching the same `device_type`
     (bulk `update_all`, no changeset overhead).
  2. Sets `active: true` on the target row via a non-bang `Repo.update/1`,
     rolling back the transaction on error.

  Returns `{:ok, %Profile{}}` with the updated record (no layouts+bindings
  preload — callers that need those should re-fetch via `get_profile/1`),
  or `{:error, %Ecto.Changeset{}}` if the changeset fails validation or
  trips the `profiles_one_active_per_device_type` partial unique index.

  This is the only safe way to toggle the active flag. The "one active
  profile per device type" invariant is enforced at the DB level by that
  partial unique index and at the application level by the `Orchestrator`
  GenServer serializing activations.

  Correctness notes for future maintainers:

  - The bulk `update_all` + changeset `update` pair is NOT atomic at the
    row level, only at the transaction level. SQLite's default journal
    mode (WAL) combined with `Repo.transaction/1` is what makes this
    safe in the single-writer case.
  - If this function is ever called from outside `Orchestrator` (which
    serializes via GenServer), the caller must hold a lock, otherwise
    two concurrent activations of different profiles for the same
    `device_type` can race: both pass the `where [p, p.active == true
    and p.id != ^profile.id]` filter and both claim the slot.
  """
  def activate_exclusive(%Profile{} = profile) do
    Repo.transaction(fn ->
      Profile
      |> where(
        [p],
        p.active == true and p.device_type == ^profile.device_type and p.id != ^profile.id
      )
      |> Repo.update_all(set: [active: false])

      case profile |> Profile.changeset(%{"active" => true}) |> Repo.update() do
        {:ok, updated} -> updated
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
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
