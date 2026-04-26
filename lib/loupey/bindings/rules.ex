defmodule Loupey.Bindings.Rules do
  @moduledoc """
  Pure functions for matching input and output rules against events and state.

  All functions are side-effect free — they take data in and return data out.
  """

  alias Hassock.EntityState
  alias Loupey.Bindings.{Binding, Expression, OutputRule}
  alias Loupey.Events.{PressEvent, RotateEvent, TouchEvent}

  # -- Input rule matching --

  @doc """
  Match an input event against a binding's input rules.

  Filters rules by trigger type, then evaluates `when` conditions top-down.
  Returns `{:actions, [action_map]}` for the first matching rule, or `:no_match`.

  Each action map has at minimum an `:action` key ("call_service" or "switch_layout")
  plus action-specific params (`:domain`, `:service`, `:target`, etc.).
  """
  @spec match_input(
          Loupey.Events.t(),
          Binding.t(),
          EntityState.t() | nil,
          Loupey.Device.Control.t() | nil
        ) ::
          {:actions, [map()]} | :no_match
  def match_input(event, binding, entity_state, control \\ nil)

  def match_input(event, %Binding{input_rules: rules}, entity_state, control) do
    trigger = event_to_trigger(event)

    event_context =
      event
      |> build_event_context()
      |> enrich_event_context(control)

    rules
    |> Enum.filter(&(&1.on == trigger))
    |> Enum.find_value(:no_match, fn rule ->
      if matches_condition?(rule.when, entity_state) do
        resolved = Enum.map(rule.actions, &resolve_action(&1, entity_state, event_context))
        {:actions, resolved}
      end
    end)
  end

  # -- Output rule matching --

  @doc """
  Match a binding's output rules against the current entity state.

  Evaluates `when` conditions top-down, returns
  `{:match, rule_idx, rule, instructions}` for the first match with
  all template expressions resolved, or `:no_match`. The `rule_idx`
  and `rule` are exposed so the Engine can detect rule transitions
  and read animation hooks (`animations`, `on_enter`, etc.) without
  re-running the match.
  """
  @spec match_output(Binding.t(), EntityState.t() | nil) ::
          {:match, non_neg_integer(), OutputRule.t(), map()} | :no_match
  def match_output(%Binding{output_rules: []}, _entity_state), do: :no_match

  def match_output(%Binding{output_rules: rules}, entity_state) do
    rules
    |> Enum.with_index()
    |> Enum.find_value(:no_match, fn {rule, idx} ->
      if matches_condition?(rule.when, entity_state) do
        {:match, idx, rule, resolve_instructions(rule.instructions, entity_state)}
      end
    end)
  end

  # -- Helpers --

  defp event_to_trigger(%PressEvent{action: :press}), do: :press
  defp event_to_trigger(%PressEvent{action: :release}), do: :release
  defp event_to_trigger(%RotateEvent{direction: :cw}), do: :rotate_cw
  defp event_to_trigger(%RotateEvent{direction: :ccw}), do: :rotate_ccw
  defp event_to_trigger(%TouchEvent{action: :start}), do: :touch_start
  defp event_to_trigger(%TouchEvent{action: :move}), do: :touch_move
  defp event_to_trigger(%TouchEvent{action: :end}), do: :touch_end

  defp matches_condition?(nil, _entity_state), do: true
  defp matches_condition?(true, _entity_state), do: true

  defp matches_condition?(expr, entity_state) when is_binary(expr) do
    Expression.eval_condition(expr, entity_state)
  end

  defp resolve_action(action_map, entity_state, event_context) do
    Map.new(action_map, fn {key, value} ->
      {key, resolve_param_value(value, entity_state, event_context)}
    end)
  end

  defp resolve_param_value(value, entity_state, event_context) when is_binary(value) do
    if String.contains?(value, "{{") do
      Expression.resolve_with_context(value, entity_state, event_context)
    else
      value
    end
  end

  defp resolve_param_value(%{} = map, entity_state, event_context) do
    Map.new(map, fn {k, v} -> {k, resolve_param_value(v, entity_state, event_context)} end)
  end

  defp resolve_param_value(value, _entity_state, _event_context), do: value

  defp build_event_context(%TouchEvent{x: x, y: y, touch_id: touch_id, control_id: control_id}) do
    %{touch_x: x, touch_y: y, touch_id: touch_id, control_id: control_id}
  end

  defp build_event_context(_event), do: %{}

  @doc """
  Enrich event context with control dimensions for touch calculations.
  """
  @spec enrich_event_context(map(), Loupey.Device.Control.t() | nil) :: map()
  def enrich_event_context(context, %{display: %{width: w, height: h}}) do
    Map.merge(context, %{strip_width: w, strip_height: h, control_width: w, control_height: h})
  end

  def enrich_event_context(context, _control), do: context

  defp resolve_instructions(instructions, entity_state) do
    Map.new(instructions, &resolve_instruction(&1, entity_state))
  end

  defp resolve_instruction({:text, %{content: _} = opts}, entity_state) do
    {:text, resolve_map_values(opts, entity_state)}
  end

  defp resolve_instruction({:text, text}, entity_state) when is_binary(text) do
    {:text, Expression.render(text, entity_state)}
  end

  defp resolve_instruction({:fill, fill}, entity_state) when is_map(fill) do
    {:fill, resolve_map_values(fill, entity_state)}
  end

  defp resolve_instruction({key, value}, entity_state) when is_binary(value) do
    {key, Expression.resolve(value, entity_state)}
  end

  defp resolve_instruction(pair, _entity_state), do: pair

  defp resolve_map_values(map, entity_state) do
    Map.new(map, fn {k, v} -> {k, Expression.resolve(v, entity_state)} end)
  end
end
