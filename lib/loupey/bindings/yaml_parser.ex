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

  alias Loupey.Bindings.{Binding, InputRule, OutputRule}

  @doc """
  Parse a YAML string into a Binding struct.
  """
  @spec parse_binding(String.t()) :: {:ok, Binding.t()} | {:error, term()}
  def parse_binding(yaml) do
    case YamlElixir.read_from_string(yaml) do
      {:ok, data} -> {:ok, build_binding(data)}
      {:error, _} = error -> error
    end
  end

  @doc """
  Parse a YAML string into a Blueprint map (name, description, inputs, rules).
  """
  @spec parse_blueprint(String.t()) :: {:ok, map()} | {:error, term()}
  def parse_blueprint(yaml) do
    case YamlElixir.read_from_string(yaml) do
      {:ok, data} ->
        blueprint = %{
          name: data["name"] || "Untitled",
          description: data["description"] || "",
          inputs: parse_blueprint_inputs(data["inputs"] || %{}),
          input_rules: parse_input_rules(data["input_rules"] || []),
          output_rules: parse_output_rules(data["output_rules"] || [])
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
        %{rule | params: resolve_inputs(rule.params, input_values)}
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
  @spec load_binding(String.t(), map()) :: {:ok, Binding.t()} | {:error, term()}
  def load_binding(path, variables \\ %{}) do
    case File.read(path) do
      {:ok, contents} ->
        substituted = substitute_variables(contents, variables)
        parse_binding(substituted)

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

  defp build_binding(data) do
    %Binding{
      entity_id: data["entity_id"],
      input_rules: parse_input_rules(data["input_rules"] || []),
      output_rules: parse_output_rules(data["output_rules"] || [])
    }
  end

  defp parse_input_rules(rules) do
    Enum.map(rules, &parse_input_rule/1)
  end

  defp parse_input_rule(rule) do
    trigger = parse_trigger(rule["on"])
    params = Map.drop(rule, ["on", "when", "action"])

    %InputRule{
      on: trigger,
      when: rule["when"],
      action: rule["action"],
      params: atomize_keys(params)
    }
  end

  defp parse_output_rules(rules) do
    Enum.map(rules, &parse_output_rule/1)
  end

  defp parse_output_rule(rule) do
    condition = parse_condition(rule["when"])
    instructions = Map.drop(rule, ["when"])

    %OutputRule{
      when: condition,
      instructions: atomize_keys(instructions)
    }
  end

  defp parse_trigger("press"), do: :press
  defp parse_trigger("release"), do: :release
  defp parse_trigger("rotate_cw"), do: :rotate_cw
  defp parse_trigger("rotate_ccw"), do: :rotate_ccw
  defp parse_trigger("touch_start"), do: :touch_start
  defp parse_trigger("touch_move"), do: :touch_move
  defp parse_trigger("touch_end"), do: :touch_end
  defp parse_trigger(other) when is_atom(other), do: other
  defp parse_trigger(other), do: String.to_atom(other)

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

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_binary(key) -> {String.to_atom(key), atomize_value(value)}
      {key, value} -> {key, atomize_value(value)}
    end)
  end

  @known_atoms ~w(
    top middle bottom left center right
    horizontal vertical
    to_top to_bottom to_left to_right
    linear radial
  )

  defp atomize_value(%{} = map), do: atomize_keys(map)
  defp atomize_value(value) when is_binary(value) and value in @known_atoms, do: String.to_atom(value)
  defp atomize_value(value), do: value

  defp resolve_inputs(map, input_values) when is_map(map) do
    Map.new(map, fn {key, value} ->
      {key, resolve_input_value(value, input_values)}
    end)
  end

  defp resolve_input_value(value, input_values) when is_binary(value) do
    Regex.replace(~r/\{\{\s*inputs\.(\w+)\s*\}\}/, value, fn _match, key ->
      to_string(Map.get(input_values, key) || Map.get(input_values, String.to_atom(key), ""))
    end)
  end

  defp resolve_input_value(%{} = map, input_values), do: resolve_inputs(map, input_values)
  defp resolve_input_value(value, _input_values), do: value
end
