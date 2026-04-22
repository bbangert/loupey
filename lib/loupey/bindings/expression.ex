defmodule Loupey.Bindings.Expression do
  @moduledoc """
  Evaluates `{{ }}` template expressions against entity state.

  Thin wrapper over `Loupey.Bindings.Expression.Evaluator` — see that
  module for the expression grammar and error model. This module owns
  the HA context shape (what `state_of`/`attr_of` look up, how entity
  state maps to context variables) and the template-rendering API used
  by the rest of the bindings stack.

  ## Scope

  - `state` — the binding entity's state string (nil if no entity_id)
  - `attributes` — the binding entity's attributes map
  - `entity_id` — the binding entity's ID string
  - Event context: `touch_x`, `touch_y`, `touch_id`, `control_id`,
    `strip_width`, `strip_height`, `control_width`, `control_height`
    (merged via `resolve_with_context/3`)
  - `state_of(id)` — get any entity's state string by ID
  - `attr_of(id, key)` — get any entity's attribute value by ID and key
  - `round/1`, arithmetic, comparisons, `||`, map access via `m["k"]`

  ## Examples

      eval(~s(state_of("light.office") == "on"), nil)
      #=> true (if light.office is on in the Hassock cache)

      render(~s({{ state_of("sensor.temp") }}°F), nil)
      #=> "72.5°F"
  """

  alias Hassock.EntityState
  alias Loupey.Bindings.Expression.Evaluator
  alias Loupey.HA

  @doc """
  Evaluate a single expression string against entity state.
  Returns the evaluated value, or `nil` on error.
  """
  @spec eval(String.t(), EntityState.t() | nil) :: term()
  def eval(expr, entity_state) do
    context = build_context(entity_state)

    case Evaluator.evaluate(expr, context) do
      {:ok, value} -> value
      {:error, _} -> nil
    end
  end

  @doc """
  Evaluate a condition — returns a boolean.
  `true` (the atom/boolean) always matches.
  nil entity_state doesn't block conditions — expressions using state_of()
  work without a binding entity.
  """
  @spec eval_condition(String.t() | true, EntityState.t() | nil) :: boolean()
  def eval_condition(true, _entity_state), do: true

  def eval_condition(expr, entity_state) do
    case eval(expr, entity_state) do
      result when result in [true, "true"] -> true
      _ -> false
    end
  end

  @doc """
  Render a template string by replacing `{{ expr }}` placeholders with
  evaluated results. Non-template strings are returned as-is.
  """
  @spec render(String.t(), EntityState.t() | nil) :: String.t()
  def render(template, entity_state) do
    context = build_context(entity_state)

    Regex.replace(~r/\{\{\s*(.+?)\s*\}\}/, template, fn _match, expr ->
      case Evaluator.evaluate(expr, context) do
        {:ok, nil} -> ""
        {:ok, value} -> to_string(value)
        {:error, _} -> ""
      end
    end)
  end

  @doc """
  Resolve a value that may be a template string or a literal.
  If it's a string containing `{{ }}`, render it. Otherwise return as-is.
  """
  @spec resolve(term(), EntityState.t() | nil) :: term()
  def resolve(value, entity_state) when is_binary(value) do
    if String.contains?(value, "{{") do
      value |> render(entity_state) |> maybe_parse_number()
    else
      value
    end
  end

  def resolve(value, _entity_state), do: value

  @doc """
  Resolve a template string with additional context variables (e.g., touch
  coordinates). Extra context is merged into the evaluator context map.
  """
  @spec resolve_with_context(String.t(), EntityState.t() | nil, map()) :: term()
  def resolve_with_context(value, entity_state, extra_context) when is_binary(value) do
    if String.contains?(value, "{{") do
      context = entity_state |> build_context() |> Map.merge(extra_context)

      value
      |> render_with_context(context)
      |> maybe_parse_number()
    else
      value
    end
  end

  @doc """
  Extract all entity IDs referenced via state_of() and attr_of() in a string.
  Used by the engine to discover which entities to subscribe to.
  """
  @spec extract_entity_refs(String.t()) :: [String.t()]
  def extract_entity_refs(text) when is_binary(text) do
    ~r/(?:state_of|attr_of)\(\s*"([^"]+)"/
    |> Regex.scan(text)
    |> Enum.map(fn [_, entity_id] -> entity_id end)
    |> Enum.uniq()
  end

  def extract_entity_refs(_), do: []

  # -- Internal --

  defp render_with_context(template, context) do
    Regex.replace(~r/\{\{\s*(.+?)\s*\}\}/, template, fn _match, expr ->
      case Evaluator.evaluate(expr, context) do
        {:ok, nil} -> ""
        {:ok, value} -> to_string(value)
        {:error, _} -> ""
      end
    end)
  end

  defp maybe_parse_number(rendered) do
    case Float.parse(rendered) do
      {num, ""} -> num
      _ -> rendered
    end
  end

  # Build the evaluator context map from entity state + our two HA-backed
  # helper functions. Keys here are the variable names expressions can
  # reference. The `state_of` / `attr_of` entries are function refs the
  # walker calls when it encounters `{:call, :state_of, …}` etc.
  defp build_context(nil) do
    %{
      state: nil,
      attributes: %{},
      entity_id: nil,
      state_of: &state_of/1,
      attr_of: &attr_of/2
    }
  end

  defp build_context(%EntityState{} = es) do
    %{
      state: es.state,
      attributes: es.attributes,
      entity_id: es.entity_id,
      state_of: &state_of/1,
      attr_of: &attr_of/2
    }
  end

  defp state_of(entity_id) do
    case HA.get_state(entity_id) do
      %{state: state} -> state
      nil -> nil
    end
  end

  defp attr_of(entity_id, attribute_name) do
    case HA.get_state(entity_id) do
      %{attributes: attrs} -> Map.get(attrs, attribute_name)
      nil -> nil
    end
  end
end
