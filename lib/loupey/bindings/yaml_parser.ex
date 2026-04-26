defmodule Loupey.Bindings.YamlParser do
  @moduledoc """
  Parses YAML binding definitions and blueprints into structs.

  ## Binding YAML Format

  ```yaml
  entity_id: "light.living_room"
  input_rules:
    - on: press
      action: call_service
      domain: light
      service: toggle
      target: "{{ entity_id }}"
  output_rules:
    - when: "{{ state == 'on' }}"
      icon: "light/on.png"
      color: "#FFD700"
    - when: "{{ state == 'off' }}"
      icon: "light/off.png"
      color: "#333333"
  ```

  ## Blueprint YAML Format

  ```yaml
  name: "Light Toggle"
  description: "Button that toggles a light"
  inputs:
    entity:
      type: entity
      domain: light
    on_color:
      type: color
      default: "#FFD700"
  input_rules:
    - on: press
      action: call_service
      domain: light
      service: toggle
      target: "{{ inputs.entity }}"
  output_rules:
    - when: "{{ state == 'on' }}"
      color: "{{ inputs.on_color }}"
  ```
  """

  alias Loupey.Animation.{Keyframes, TransitionSpec}
  alias Loupey.Bindings.{Binding, InputRule, OutputRule}

  @doc """
  Parse a YAML string into a Binding struct.

  Pass `:keyframes` in `opts` to provide a profile-scoped registry for
  resolving string animation references (e.g. `animation: "breathe"`).
  Unknown references raise — fail loud at load time rather than silent
  no-op at render time.
  """
  @spec parse_binding(String.t(), keyword()) :: {:ok, Binding.t()} | {:error, term()}
  def parse_binding(yaml, opts \\ []) do
    case YamlElixir.read_from_string(yaml) do
      {:ok, data} -> {:ok, build_binding(data, opts)}
      {:error, _} = error -> error
    end
  end

  @doc """
  Parse a YAML string into a Blueprint map (name, description, inputs, rules).
  """
  @spec parse_blueprint(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def parse_blueprint(yaml, opts \\ []) do
    case YamlElixir.read_from_string(yaml) do
      {:ok, data} ->
        blueprint = %{
          name: data["name"] || "Untitled",
          description: data["description"] || "",
          inputs: parse_blueprint_inputs(data["inputs"] || %{}),
          input_rules: parse_input_rules(data["input_rules"] || [], opts),
          output_rules: parse_output_rules(data["output_rules"] || [], opts)
        }

        {:ok, blueprint}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Instantiate a blueprint with user-provided input values.

  Replaces `{{ inputs.key }}` references in rules with the supplied values.
  Returns a Binding struct.
  """
  @spec instantiate_blueprint(map(), map()) :: Binding.t()
  def instantiate_blueprint(blueprint, input_values) do
    entity_id = Map.get(input_values, "entity") || Map.get(input_values, :entity)

    input_rules =
      Enum.map(blueprint.input_rules, fn rule ->
        actions = Enum.map(rule.actions, &resolve_inputs(&1, input_values))
        %{rule | actions: actions}
      end)

    output_rules =
      Enum.map(blueprint.output_rules, fn rule ->
        %{rule | instructions: resolve_inputs(rule.instructions, input_values)}
      end)

    %Binding{
      entity_id: entity_id,
      input_rules: input_rules,
      output_rules: output_rules
    }
  end

  @doc """
  Load and parse a blueprint from a YAML file.
  """
  @spec load_blueprint(String.t()) :: {:ok, map()} | {:error, term()}
  def load_blueprint(path) do
    case File.read(path) do
      {:ok, contents} -> parse_blueprint(contents)
      {:error, _} = error -> error
    end
  end

  @doc """
  Load a binding from a YAML file, substituting variables in the YAML text
  before parsing. This allows YAML files to use `{{ entity_id }}` and other
  placeholders that are replaced with concrete values at load time.

  ## Example

      load_binding("light_toggle.yaml", %{"entity_id" => "light.living_room"})

  """
  @spec load_binding(String.t(), map(), keyword()) :: {:ok, Binding.t()} | {:error, term()}
  def load_binding(path, variables \\ %{}, opts \\ []) do
    case File.read(path) do
      {:ok, contents} ->
        substituted = substitute_variables(contents, variables)
        parse_binding(substituted, opts)

      {:error, _} = error ->
        error
    end
  end

  defp substitute_variables(yaml, variables) do
    Enum.reduce(variables, yaml, fn {key, value}, acc ->
      String.replace(acc, "{{ #{key} }}", to_string(value))
    end)
  end

  # -- Internal parsing --

  defp build_binding(data, opts) do
    %Binding{
      entity_id: data["entity_id"],
      input_rules: parse_input_rules(data["input_rules"] || [], opts),
      output_rules: parse_output_rules(data["output_rules"] || [], opts)
    }
  end

  defp parse_input_rules(rules, opts) do
    Enum.map(rules, &parse_input_rule(&1, opts))
  end

  defp parse_input_rule(rule, opts) do
    trigger = parse_trigger(rule["on"])
    {animation_keys, action_data} = pop_animation_keys(rule)

    actions =
      cond do
        is_list(rule["actions"]) ->
          Enum.map(rule["actions"], &atomize_keys/1)

        rule["action"] ->
          params = Map.drop(action_data, ["on", "when", "action"])
          [Map.merge(%{action: rule["action"]}, atomize_keys(params))]

        true ->
          []
      end

    %InputRule{
      on: trigger,
      when: rule["when"],
      actions: actions,
      animations: parse_animations(animation_keys, opts)
    }
  end

  defp parse_output_rules(rules, opts) do
    Enum.map(rules, &parse_output_rule(&1, opts))
  end

  defp parse_output_rule(rule, opts) do
    condition = parse_condition(rule["when"])
    {animation_keys, rest} = pop_animation_keys(rule)
    instructions = Map.drop(rest, ["when"])
    transitions_yaml = animation_keys["transitions"] || animation_keys["transition"]

    %OutputRule{
      when: condition,
      instructions: atomize_keys(instructions),
      animations: parse_animations(animation_keys, opts),
      on_enter: parse_animation_list(animation_keys["on_enter"], opts),
      transitions: parse_transitions(transitions_yaml),
      on_change: parse_on_change(animation_keys["on_change"], opts)
    }
  end

  @animation_keys ~w(animation animations on_enter transition transitions on_change)

  defp pop_animation_keys(rule) do
    Enum.reduce(@animation_keys, {%{}, rule}, fn key, {anim, rest} ->
      case Map.pop(rest, key) do
        {nil, rest} -> {anim, rest}
        {value, rest} -> {Map.put(anim, key, value), rest}
      end
    end)
  end

  defp parse_animations(animation_keys, opts) do
    parse_animation_list(animation_keys["animation"], opts) ++
      parse_animation_list(animation_keys["animations"], opts)
  end

  defp parse_animation_list(nil, _opts), do: []

  defp parse_animation_list(list, opts) when is_list(list) do
    Enum.map(list, &parse_animation_value(&1, opts))
  end

  defp parse_animation_list(value, opts), do: [parse_animation_value(value, opts)]

  defp parse_animation_value(name, opts) when is_binary(name) do
    registry = Keyword.get(opts, :keyframes, %{})

    case Map.fetch(registry, name) do
      {:ok, kf} ->
        kf

      :error ->
        raise ArgumentError,
              "unknown keyframe reference #{inspect(name)} — known: #{inspect(Map.keys(registry))}"
    end
  end

  defp parse_animation_value(map, _opts) when is_map(map) do
    map |> atomize_keys() |> Keyframes.parse()
  end

  # Walk a nested per-property `transitions` map, flattening to
  # `%{[atom] => TransitionSpec.t()}` keyed by the engine's diff path
  # representation. A leaf is detected by presence of `:duration_ms` —
  # everything else at the same level is rejected as ambiguous (would
  # otherwise silently land in the spec's unknown-keys check).
  #
  # Top-level `:duration_ms` (path == []) is also rejected — a
  # transition without a property to animate is meaningless.
  defp parse_transitions(nil), do: %{}

  defp parse_transitions(map) when is_map(map) do
    walk_transitions(atomize_keys(map), [])
  end

  defp walk_transitions(map, []) when is_map(map) and is_map_key(map, :duration_ms) do
    raise ArgumentError,
          "transitions: top-level :duration_ms has no property to animate — " <>
            "wrap it under a property name (e.g. `transitions: { color: { duration_ms: 300 } }`)"
  end

  defp walk_transitions(map, path) when is_map(map) and is_map_key(map, :duration_ms) do
    require_transition_leaf!(map, path)
    %{Enum.reverse(path) => TransitionSpec.parse(map)}
  end

  defp walk_transitions(map, path) when is_map(map) do
    walk_subpaths(map, path, &walk_transitions/2, "transition")
  end

  defp walk_subpaths(map, path, walker, label) do
    Enum.reduce(map, %{}, fn {key, value}, acc ->
      validate_path_segment!(key, path, label)

      unless is_map(value) do
        raise ArgumentError,
              "expected map at #{label} path " <>
                "#{inspect(Enum.reverse([key | path]))}, got #{inspect(value)}"
      end

      Map.merge(acc, walker.(value, [key | path]))
    end)
  end

  # Path segments must be atoms — `atomize_keys/1` only converts known
  # YAML keys (those in `@atom_map`) and leaves anything else as a
  # string. A typo'd property name (`colro:` instead of `color:`) would
  # otherwise produce a path like `["colro"]` that `Engine.diff_paths/3`
  # can never match against atom-keyed resolved instructions — silently
  # making the whole `transitions:`/`on_change:` entry a no-op. Fail
  # loud at parse time instead.
  defp validate_path_segment!(key, _path, _label) when is_atom(key), do: :ok

  defp validate_path_segment!(key, path, label) do
    raise ArgumentError,
          "unknown #{label} property #{inspect(key)} at path " <>
            "#{inspect(Enum.reverse([key | path]))}. Property names must be in " <>
            "Loupey.Bindings.YamlParser's atom whitelist (e.g. :color, :fill, " <>
            ":amount). Check for a typo, or add the property to `@atom_map`."
  end

  # A transition leaf accepts only `:duration_ms` and `:easing`. Any
  # other key at this level is treated as a sub-path the author meant
  # to nest one level deeper — raise rather than swallow it as an
  # unknown-keys error from `TransitionSpec.parse/1`.
  defp require_transition_leaf!(map, path) do
    extras = Map.keys(map) -- [:duration_ms, :easing]

    unless extras == [] do
      raise ArgumentError,
            "ambiguous transition spec at path #{inspect(Enum.reverse(path))}: " <>
              ":duration_ms is present (treated as leaf) but unrecognized keys " <>
              "#{inspect(extras)} also appear. Transition leaves accept only " <>
              ":duration_ms and :easing — move sub-paths up a level."
    end
  end

  # Walk a nested per-property `on_change` map, flattening to
  # `%{[atom] => Keyframes.t()}`. Leaf detection: presence of
  # `:duration_ms` (inline keyframe) or `:effect` (effect shorthand).
  # `:keyframes` is the only nested-map value allowed at a leaf level —
  # any other nested map is flagged as a phantom path so authoring
  # mistakes fail loud rather than silently land in `extras`.
  #
  # String keyframe references (e.g. `on_change: { color: "ripple" }`)
  # are rejected for v2 — registry lookup at this level adds parser
  # complexity for no current use case. Inline maps and effect
  # shorthand cover authoring needs.
  defp parse_on_change(nil, _opts), do: %{}

  defp parse_on_change(map, opts) when is_map(map) do
    walk_on_change(atomize_keys(map), [], opts)
  end

  defp walk_on_change(map, [], _opts)
       when is_map(map) and (is_map_key(map, :duration_ms) or is_map_key(map, :effect)) do
    raise ArgumentError,
          "on_change: top-level keyframe has no property to react to — " <>
            "wrap it under a property name (e.g. `on_change: { color: { effect: ripple } }`)"
  end

  defp walk_on_change(map, path, _opts)
       when is_map(map) and (is_map_key(map, :duration_ms) or is_map_key(map, :effect)) do
    require_on_change_leaf!(map, path)
    %{Enum.reverse(path) => Keyframes.parse(map)}
  end

  defp walk_on_change(map, path, opts) when is_map(map) do
    Enum.reduce(map, %{}, &recurse_on_change_entry(&1, &2, path, opts))
  end

  defp recurse_on_change_entry({key, value}, acc, path, opts) do
    validate_path_segment!(key, path, "on_change")

    if is_map(value) do
      Map.merge(acc, walk_on_change(value, [key | path], opts))
    else
      raise ArgumentError,
            "on_change at path #{inspect(Enum.reverse([key | path]))}: " <>
              "expected a nested map or leaf keyframe spec " <>
              "(with :duration_ms or :effect), got #{inspect(value)}. " <>
              "String keyframe references are not supported in on_change — " <>
              "use an inline map or `effect:` shorthand."
    end
  end

  # Allowed nested-map values at an on_change leaf. Only `:keyframes`
  # is legitimately a map (the stops dict); anything else nested at
  # this level is a phantom path and must be flagged.
  @on_change_leaf_nested_keys [:keyframes]

  defp require_on_change_leaf!(map, path) do
    phantoms =
      Enum.flat_map(map, fn {key, value} ->
        if is_map(value) and key not in @on_change_leaf_nested_keys, do: [key], else: []
      end)

    unless phantoms == [] do
      raise ArgumentError,
            "ambiguous on_change spec at path #{inspect(Enum.reverse(path))}: " <>
              "leaf marker (:duration_ms or :effect) is present but nested-map " <>
              "keys #{inspect(phantoms)} look like sub-paths. Either remove the " <>
              "leaf marker here or move sub-paths up a level."
    end
  end

  defp parse_trigger("press"), do: :press
  defp parse_trigger("release"), do: :release
  defp parse_trigger("rotate_cw"), do: :rotate_cw
  defp parse_trigger("rotate_ccw"), do: :rotate_ccw
  defp parse_trigger("touch_start"), do: :touch_start
  defp parse_trigger("touch_move"), do: :touch_move
  defp parse_trigger("touch_end"), do: :touch_end
  defp parse_trigger(other) when is_atom(other), do: other
  # Unknown trigger strings stay as strings — no downstream rule declares
  # a trigger we don't list above, so the value won't match `Rules.matches?/2`
  # regardless of shape, and the binding is gracefully ignored.
  defp parse_trigger(other), do: other

  defp parse_condition(true), do: true
  defp parse_condition("true"), do: true
  defp parse_condition(nil), do: true
  defp parse_condition(expr), do: expr

  defp parse_blueprint_inputs(inputs) do
    Map.new(inputs, fn {name, config} ->
      {name,
       %{
         type: config["type"] || "string",
         domain: config["domain"],
         description: config["description"] || "",
         default: config["default"]
       }}
    end)
  end

  # Compile-time whitelist of YAML strings that get converted to atoms. Both
  # map keys (in `atomize_keys/1`) and map values (in `atomize_value/1`)
  # look up here. Anything not in the map stays as a string.
  #
  # The atoms on the right-hand side are embedded as literal values in the
  # compiled function bodies below, which forces them into YamlParser's own
  # beam atom table. Without this anchor, atoms like `:icon` / `:to_top` /
  # `:entity_id` live only in the compile-time atom table (via e.g.
  # `~w()a` in an unused module attribute) and may not be interned at
  # runtime until some other module that references them literally happens
  # to load. In tests that's never an issue (ExUnit eagerly loads every
  # app module), but dev-server lazy module loading surfaced it as
  # `ArgumentError: not an already existing atom` in `String.to_existing_atom/1`
  # and then, after the value-atom fix, as silent string-keyed binding
  # trees that never matched `%{icon: …}` pattern heads downstream.
  #
  # The list itself is not an atom-exhaustion boundary — that contract
  # is moot for Loupey's single-user local-control threat model. It's
  # just "which YAML identifiers do we atomize vs. leave as strings".
  # `service_data`'s inner payload (brightness, rgb_color, transition,
  # entity-specific arbitrary keys) is deliberately NOT in the map: those
  # forward verbatim to `Hassock.ServiceCall` which accepts either form.
  @atom_map %{
    # Binding tree structure
    "entity_id" => :entity_id,
    "input_rules" => :input_rules,
    "output_rules" => :output_rules,
    "on" => :on,
    "when" => :when,
    "action" => :action,
    "actions" => :actions,
    "instructions" => :instructions,

    # Action payload
    "domain" => :domain,
    "service" => :service,
    "target" => :target,
    "service_data" => :service_data,
    "layout" => :layout,

    # Output-rule instructions (top level)
    "icon" => :icon,
    "color" => :color,
    "text" => :text,
    "background" => :background,
    "fill" => :fill,

    # Text sub-map
    "content" => :content,
    "font_size" => :font_size,
    "align" => :align,
    "valign" => :valign,
    "orientation" => :orientation,

    # Fill sub-map
    "amount" => :amount,
    "direction" => :direction,

    # Enumerated value atoms (text align/valign, fill direction, gradient type)
    "top" => :top,
    "middle" => :middle,
    "bottom" => :bottom,
    "left" => :left,
    "center" => :center,
    "right" => :right,
    "horizontal" => :horizontal,
    "vertical" => :vertical,
    "to_top" => :to_top,
    "to_bottom" => :to_bottom,
    "to_left" => :to_left,
    "to_right" => :to_right,
    "linear" => :linear,
    "radial" => :radial,

    # Animation hooks on rules.
    "animation" => :animation,
    "animations" => :animations,
    "on_enter" => :on_enter,
    "transition" => :transition,
    "transitions" => :transitions,
    "on_change" => :on_change,
    "keyframes" => :keyframes,
    "overlay" => :overlay,
    "transform" => :transform,
    "transforms" => :transforms,

    # Keyframe definition fields
    "duration_ms" => :duration_ms,
    "easing" => :easing,
    "iterations" => :iterations,
    "infinite" => :infinite,
    # `direction` already declared above for fill direction; the same atom
    # name is reused for animation direction.
    "normal" => :normal,
    "reverse" => :reverse,
    "alternate" => :alternate,
    "alternate_reverse" => :alternate_reverse,
    "translate_x" => :translate_x,
    "translate_y" => :translate_y,
    "scale" => :scale,
    "rotate" => :rotate,
    "effect" => :effect,
    "name" => :name,

    # Easing names (curve presets)
    "ease" => :ease,
    "ease_in" => :ease_in,
    "ease_out" => :ease_out,
    "ease_in_out" => :ease_in_out,
    "step_start" => :step_start,
    "step_end" => :step_end,
    "cubic_bezier" => :cubic_bezier,

    # Effect names
    "pulse" => :pulse,
    "flash" => :flash,
    "shake" => :shake,
    "wiggle" => :wiggle,
    "squish" => :squish,
    "ripple" => :ripple
  }

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_binary(key) -> {Map.get(@atom_map, key, key), atomize_value(value)}
      {key, value} -> {key, atomize_value(value)}
    end)
  end

  defp atomize_value(%{} = map), do: atomize_keys(map)
  defp atomize_value(value) when is_binary(value), do: Map.get(@atom_map, value, value)
  defp atomize_value(value), do: value

  defp resolve_inputs(map, input_values) when is_map(map) do
    Map.new(map, fn {key, value} ->
      {key, resolve_input_value(value, input_values)}
    end)
  end

  defp resolve_input_value(value, input_values) when is_binary(value) do
    Regex.replace(~r/\{\{\s*inputs\.(\w+)\s*\}\}/, value, fn _match, key ->
      # Blueprint input names are user-authored and unbounded. Keep the
      # lookup string-keyed; callers are expected to pass string keys
      # (Phoenix form params naturally are). If a caller passes an atom-
      # keyed map, the template substitution falls back to "".
      to_string(Map.get(input_values, key, ""))
    end)
  end

  defp resolve_input_value(%{} = map, input_values), do: resolve_inputs(map, input_values)
  defp resolve_input_value(value, _input_values), do: value
end
