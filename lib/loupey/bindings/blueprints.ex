defmodule Loupey.Bindings.Blueprints do
  @moduledoc """
  Loads and manages binding blueprints.

  Blueprints are parameterized binding templates stored as YAML files
  in `priv/blueprints/`. Each blueprint declares typed inputs that the
  user fills in to produce a concrete binding.
  """

  alias Loupey.Bindings.YamlParser

  @blueprints_dir Application.app_dir(:loupey, "priv/blueprints")

  @doc """
  List all available blueprints with their metadata.
  Returns a list of `%{id: filename, name: ..., description: ..., inputs: ...}`.
  """
  @spec list() :: [map()]
  def list do
    @blueprints_dir
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".yaml"))
    |> Enum.sort()
    |> Enum.flat_map(&load_metadata/1)
  end

  @doc """
  Load a blueprint by its ID (filename without extension).
  """
  @spec get(String.t()) :: {:ok, map()} | {:error, term()}
  def get(id) do
    path = Path.join(@blueprints_dir, "#{id}.yaml")
    YamlParser.load_blueprint(path)
  end

  @doc """
  Instantiate a blueprint with the given input values.
  Returns the generated binding YAML string.
  """
  @spec instantiate(String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def instantiate(id, input_values) do
    with {:ok, blueprint} <- get(id) do
      binding = YamlParser.instantiate_blueprint(blueprint, input_values)
      entity_id = Map.get(input_values, "entity") || Map.get(input_values, :entity)
      yaml = binding_to_yaml(binding, entity_id)
      {:ok, yaml}
    end
  end

  defp load_metadata(filename) do
    path = Path.join(@blueprints_dir, filename)
    id = Path.rootname(filename)

    case YamlParser.load_blueprint(path) do
      {:ok, blueprint} ->
        [%{
          id: id,
          name: blueprint.name,
          description: blueprint.description,
          inputs: blueprint.inputs
        }]

      _ ->
        []
    end
  end

  defp binding_to_yaml(binding, entity_id) do
    parts =
      if entity_id && entity_id != "",
        do: ["entity_id: \"#{entity_id}\""],
        else: []

    parts = parts ++ ["input_rules:"] ++ rules_to_yaml(binding.input_rules)
    parts = parts ++ ["output_rules:"] ++ output_rules_to_yaml(binding.output_rules)

    Enum.join(parts, "\n") <> "\n"
  end

  defp rules_to_yaml([]), do: ["  []"]

  defp rules_to_yaml(rules) do
    Enum.flat_map(rules, fn rule ->
      lines = ["  - on: #{rule.on}"]
      lines = if rule.when, do: lines ++ ["    when: '#{rule.when}'"], else: lines
      lines = lines ++ ["    action: #{rule.action}"]

      lines ++
        Enum.flat_map(rule.params, fn
          {:on, _} -> []
          {:when, _} -> []
          {:action, _} -> []
          {key, %{} = map} ->
            ["    #{key}:"] ++ Enum.flat_map(map, &nested_yaml_line("      ", &1))
          {key, value} ->
            [yaml_value_line("    ", key, value)]
        end)
    end)
  end

  defp output_rules_to_yaml([]), do: ["  []"]

  defp output_rules_to_yaml(rules) do
    Enum.flat_map(rules, fn rule ->
      when_val = if rule.when == true, do: "true", else: "'#{rule.when}'"
      lines = ["  - when: #{when_val}"]

      lines ++
        Enum.flat_map(rule.instructions, fn
          {:text, %{} = text} ->
            ["    text:"] ++ Enum.flat_map(text, &nested_yaml_line("      ", &1))
          {:fill, %{} = fill} ->
            ["    fill:"] ++ Enum.flat_map(fill, &nested_yaml_line("      ", &1))
          {key, value} ->
            [yaml_value_line("    ", key, value)]
        end)
    end)
  end

  defp nested_yaml_line(prefix, {key, value}) do
    [yaml_value_line(prefix, key, value)]
  end

  defp yaml_value_line(prefix, key, value) when is_binary(value) do
    "#{prefix}#{key}: \"#{value}\""
  end

  defp yaml_value_line(prefix, key, value) do
    "#{prefix}#{key}: #{value}"
  end
end
