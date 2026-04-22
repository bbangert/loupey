defmodule Loupey.Bindings.LayoutEngine do
  @moduledoc """
  Pure functions for layout switching and rendering.

  Operates on Profile, Layout, and Binding data to produce RenderCommands.
  No side effects — the BindingEngine GenServer calls these functions.
  """

  require Logger

  alias Loupey.Bindings.{Expression, Layout, Profile, Rules}
  alias Loupey.Device.{Control, Spec}
  alias Loupey.Graphics.Renderer
  alias Hassock.EntityState
  alias Loupey.RenderCommands.{DrawBuffer, SetLED}

  @doc """
  Switch the active layout in a profile.

  Returns the updated profile and all RenderCommands needed to draw the new
  layout on the device.
  """
  @spec switch_layout(Profile.t(), String.t(), %{String.t() => EntityState.t()}, Spec.t()) ::
          {Profile.t(), [Loupey.RenderCommands.t()]}
  def switch_layout(%Profile{} = profile, layout_id, entity_states, spec) do
    profile = %{profile | active_layout: layout_id}

    case Map.get(profile.layouts, layout_id) do
      nil ->
        {profile, []}

      layout ->
        commands = render_layout(layout, entity_states, spec)
        {profile, commands}
    end
  end

  @doc """
  Render all bindings in a layout, producing RenderCommands for every control.

  Used on layout switch, startup, and full refresh.
  """
  @spec render_layout(Layout.t(), %{String.t() => EntityState.t()}, Spec.t()) ::
          [Loupey.RenderCommands.t()]
  def render_layout(%Layout{bindings: bindings}, entity_states, spec) do
    Enum.flat_map(bindings, fn {control_id, control_bindings} ->
      control = Spec.find_control(spec, control_id)

      if control do
        render_control_bindings(control, control_bindings, entity_states)
      else
        []
      end
    end)
  end

  @doc """
  Produce RenderCommands that clear all display and LED controls to black/off.
  Used before re-rendering to ensure removed bindings don't leave stale content.
  """
  @spec clear_all(Spec.t()) :: [Loupey.RenderCommands.t()]
  def clear_all(spec) do
    Enum.flat_map(spec.controls, &clear_control/1)
  end

  defp clear_control(%Control{display: %{} = display} = control) do
    pixels = Renderer.render_solid(control, :black)

    [
      %DrawBuffer{
        control_id: control.id,
        x: 0,
        y: 0,
        width: display.width,
        height: display.height,
        pixels: pixels
      }
    ] ++ clear_led(control)
  end

  defp clear_control(control), do: clear_led(control)

  defp clear_led(control) do
    if Control.has_capability?(control, :led),
      do: [%SetLED{control_id: control.id, color: "#000000"}],
      else: []
  end

  @doc """
  Render a single control's bindings, producing RenderCommands.

  Used when a specific entity's state changes — only re-render controls
  bound to that entity.
  """
  @spec render_for_entity(Layout.t(), String.t(), EntityState.t(), Spec.t()) ::
          [Loupey.RenderCommands.t()]
  def render_for_entity(%Layout{bindings: bindings}, entity_id, entity_state, spec) do
    bindings
    |> Enum.filter(fn {_control_id, control_bindings} ->
      Enum.any?(control_bindings, &binding_references_entity?(&1, entity_id))
    end)
    |> Enum.flat_map(fn {control_id, control_bindings} ->
      control = Spec.find_control(spec, control_id)
      relevant = Enum.filter(control_bindings, &binding_references_entity?(&1, entity_id))

      if control do
        render_control_bindings(control, relevant, %{entity_id => entity_state})
      else
        []
      end
    end)
  end

  defp binding_references_entity?(binding, entity_id) do
    # Check direct entity_id (backward compat)
    # Check output rule expressions for state_of("entity_id")
    binding.entity_id == entity_id ||
      Enum.any?(binding.output_rules, fn rule ->
        references_entity_in_rule?(rule, entity_id)
      end)
  end

  defp references_entity_in_rule?(rule, entity_id) do
    when_refs = if is_binary(rule.when), do: Expression.extract_entity_refs(rule.when), else: []
    instr_refs = extract_instruction_refs(rule.instructions)
    entity_id in (when_refs ++ instr_refs)
  end

  defp extract_instruction_refs(instructions) when is_map(instructions) do
    instructions
    |> Map.values()
    |> Enum.flat_map(fn
      v when is_binary(v) -> Expression.extract_entity_refs(v)
      %{} = m -> m |> Map.values() |> Enum.flat_map(&extract_instruction_refs_value/1)
      _ -> []
    end)
  end

  defp extract_instruction_refs(_), do: []

  defp extract_instruction_refs_value(v) when is_binary(v), do: Expression.extract_entity_refs(v)
  defp extract_instruction_refs_value(_), do: []

  # -- Internals --

  defp render_control_bindings(control, bindings, entity_states) do
    Enum.flat_map(bindings, fn binding ->
      entity_state = if binding.entity_id, do: Map.get(entity_states, binding.entity_id)
      to_render_commands(binding, entity_state, control)
    end)
  end

  defp to_render_commands(binding, entity_state, control) do
    case Rules.match_output(binding, entity_state) do
      {:match, instructions} ->
        build_commands(instructions, control)

      :no_match ->
        []
    end
  end

  defp build_commands(instructions, %Control{} = control) do
    display_cmd = build_display_command(instructions, control)
    led_cmd = build_led_command(instructions, control)
    Enum.reject([display_cmd, led_cmd], &is_nil/1)
  end

  defp build_display_command(instructions, %Control{display: display} = control)
       when not is_nil(display) do
    # Load icon if referenced by path
    instructions = maybe_load_icon(instructions, display)

    pixels = Renderer.render_frame(instructions, control)

    %DrawBuffer{
      control_id: control.id,
      x: 0,
      y: 0,
      width: display.width,
      height: display.height,
      pixels: pixels
    }
  end

  defp build_display_command(_instructions, _control), do: nil

  defp build_led_command(%{color: color}, %Control{} = control)
       when is_binary(color) do
    if Control.has_capability?(control, :led) do
      %SetLED{control_id: control.id, color: color}
    end
  end

  defp build_led_command(_instructions, _control), do: nil

  defp maybe_load_icon(%{icon: path} = instructions, display) when is_binary(path) do
    has_text = Map.has_key?(instructions, :text)
    min_dim = min(display.width, display.height)
    # Leave room for text label at the bottom when text is present
    max_dim = if has_text, do: round(min_dim * 0.65), else: min_dim - 4

    case load_icon(path, max_dim) do
      {:ok, img} -> %{instructions | icon: img}
      :error -> Map.delete(instructions, :icon)
    end
  end

  defp maybe_load_icon(instructions, _display), do: instructions

  defp load_icon(path, max_dim) do
    {:ok, Image.thumbnail!(path, max_dim)}
  rescue
    error ->
      Logger.debug(
        "LayoutEngine.load_icon: failed to thumbnail #{inspect(path)}: #{inspect(error)}"
      )

      :error
  end
end
