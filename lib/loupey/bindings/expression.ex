defmodule Loupey.Bindings.Expression do
  @moduledoc """
  Evaluates `{{ }}` template expressions against entity state.

  Expressions are Elixir code snippets with access to:
  - `state` — the binding entity's state string (backward compat, nil if no entity_id)
  - `attributes` — the binding entity's attributes map (backward compat)
  - `entity_id` — the binding entity's ID string (backward compat)
  - `state_of(id)` — get any entity's state string by ID
  - `attr_of(id, key)` — get any entity's attribute value by ID and key

  ## Examples

      eval(~s(state_of("light.office") == "on"), nil)
      #=> true (if light.office is on in the StateCache)

      render(~s({{ state_of("sensor.temp") }}°F), nil)
      #=> "72.5°F"

      render(~s({{ attr_of("light.office", "brightness") }}), nil)
      #=> "255"

  """

  alias Loupey.HA.EntityState

  @doc """
  Evaluate a single expression string against entity state.
  Returns the evaluated value, or `nil` on error.
  """
  @spec eval(String.t(), EntityState.t() | nil) :: term()
  def eval(expr, entity_state) do
    bindings = build_bindings(entity_state)
    # Rewrite state_of("x") → state_of.("x") so the binding variable is called as a function
    rewritten = rewrite_function_calls(expr)
    {result, _} = Code.eval_string(rewritten, bindings)
    result
  rescue
    _ -> nil
  end

  @doc """
  Evaluate a condition — returns a boolean.
  `true` (the atom/boolean) always matches.
  Unlike before, nil entity_state no longer blocks conditions —
  expressions using state_of() work without a binding entity.
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
    Regex.replace(~r/\{\{\s*(.+?)\s*\}\}/, template, fn _match, expr ->
      case eval(expr, entity_state) do
        nil -> ""
        value -> to_string(value)
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
      rendered = render(value, entity_state)

      case Float.parse(rendered) do
        {num, ""} -> num
        _ -> rendered
      end
    else
      value
    end
  end

  def resolve(value, _entity_state), do: value

  @doc """
  Resolve a template string with additional context variables (e.g., touch coordinates).
  Extra context is merged into the expression bindings.
  """
  @spec resolve_with_context(String.t(), EntityState.t() | nil, map()) :: term()
  def resolve_with_context(value, entity_state, extra_context) when is_binary(value) do
    if String.contains?(value, "{{") do
      bindings = build_bindings(entity_state) ++ Enum.to_list(extra_context)

      rendered =
        Regex.replace(~r/\{\{\s*(.+?)\s*\}\}/, value, fn _match, expr ->
          try do
            {result, _} = Code.eval_string(rewrite_function_calls(expr), bindings)
            to_string(result)
          rescue
            _ -> ""
          end
        end)

      case Float.parse(rendered) do
        {num, ""} -> num
        _ -> rendered
      end
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

  # Rewrite state_of("x") → state_of.("x") and attr_of("x", "y") → attr_of.("x", "y")
  # so Code.eval_string treats them as variable function calls, not module function calls.
  defp rewrite_function_calls(expr) do
    expr
    |> String.replace("state_of(", "state_of.(")
    |> String.replace("attr_of(", "attr_of.(")
  end

  # -- Bindings --

  defp build_bindings(nil) do
    [state: nil, attributes: %{}, entity_id: nil] ++ base_bindings()
  end

  defp build_bindings(%EntityState{} = es) do
    [state: es.state, attributes: es.attributes, entity_id: es.entity_id] ++ base_bindings()
  end

  defp base_bindings do
    [state_of: &state_of/1, attr_of: &attr_of/2]
  end

  defp state_of(entity_id) do
    case Loupey.HA.StateCache.get(entity_id) do
      %{state: state} -> state
      nil -> nil
    end
  end

  defp attr_of(entity_id, attribute_name) do
    case Loupey.HA.StateCache.get(entity_id) do
      %{attributes: attrs} -> Map.get(attrs, attribute_name)
      nil -> nil
    end
  end
end
