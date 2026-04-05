defmodule Loupey.Bindings.Expression do
  @moduledoc """
  Evaluates `{{ }}` template expressions against entity state.

  Expressions are Elixir code snippets with access to:
  - `state` — the entity's state string (e.g., "on", "off", "72.5")
  - `attributes` — the entity's attributes map (string keys)
  - `entity_id` ��� the entity's ID string

  ## Examples

      eval("state == 'on'", entity_state)
      #=> true

      eval("(attributes[\"brightness\"] / 255) * 100", entity_state)
      #=> 50.2

      eval("if state == 'on', do: \"#FFD700\", else: \"#333333\"", entity_state)
      #=> "#FFD700"

  For template strings (containing `{{ }}`), use `render/2` which replaces
  each `{{ expr }}` with its evaluated result:

      render("Temperature: {{ state }}°F", entity_state)
      #=> "Temperature: 72.5°F"

  """

  alias Loupey.HA.EntityState

  @doc """
  Evaluate a single expression string against entity state.
  Returns the evaluated value, or `nil` on error.
  """
  @spec eval(String.t(), EntityState.t() | nil) :: term()
  def eval(expr, entity_state) do
    bindings = build_bindings(entity_state)

    {result, _} = Code.eval_string(expr, bindings)
    result
  rescue
    _ -> nil
  end

  @doc """
  Evaluate a condition — returns a boolean.
  `true` (the atom/boolean) always matches.
  `nil` entity state causes non-true conditions to return false.
  """
  @spec eval_condition(String.t() | true, EntityState.t() | nil) :: boolean()
  def eval_condition(true, _entity_state), do: true
  def eval_condition(_expr, nil), do: false

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

      # Try to parse back to number if the entire string is numeric
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

  Extra context is merged into the expression bindings alongside state/attributes/entity_id.
  """
  @spec resolve_with_context(String.t(), EntityState.t() | nil, map()) :: term()
  def resolve_with_context(value, entity_state, extra_context) when is_binary(value) do
    if String.contains?(value, "{{") do
      bindings = build_bindings(entity_state) ++ Enum.to_list(extra_context)

      rendered =
        Regex.replace(~r/\{\{\s*(.+?)\s*\}\}/, value, fn _match, expr ->
          try do
            {result, _} = Code.eval_string(expr, bindings)
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

  defp build_bindings(nil) do
    [state: nil, attributes: %{}, entity_id: nil]
  end

  defp build_bindings(%EntityState{} = es) do
    [state: es.state, attributes: es.attributes, entity_id: es.entity_id]
  end
end
