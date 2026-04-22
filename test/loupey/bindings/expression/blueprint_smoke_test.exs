defmodule Loupey.Bindings.Expression.BlueprintSmokeTest do
  @moduledoc """
  Smoke test: every expression in every shipped `priv/blueprints/*.yaml`
  must parse successfully through `Evaluator.parse/1`.

  This is the whitelist-completeness guard. If a blueprint uses an
  expression form the evaluator doesn't recognize, this test fails at
  load time — catching a grammar gap before a binding silently breaks
  for the user at render time.

  The test does NOT evaluate with HA context (no real Hassock cache in
  CI). `Evaluator.evaluate/2` needs `state_of`/`attr_of` function refs,
  which we stub; for this phase we only assert parse-level validity.
  """

  use ExUnit.Case, async: true

  alias Loupey.Bindings.Expression.Evaluator

  @blueprints_dir Path.expand("../../../../priv/blueprints", __DIR__)

  setup_all do
    paths = Path.wildcard(Path.join(@blueprints_dir, "*.yaml"))

    # Fail loud if the wildcard returns nothing — that would silently
    # make this test a no-op.
    refute paths == [], "no blueprints found at #{@blueprints_dir}"

    {:ok, blueprints: paths}
  end

  describe "every shipped blueprint's expressions parse through the evaluator" do
    @tag :tmp_dir
    test "every `when:` condition and `{{ … }}` template parses", %{blueprints: paths} do
      results =
        Enum.flat_map(paths, fn path ->
          yaml = File.read!(path)
          # Pre-substitute {{ inputs.X }} with realistic values so we see
          # the expression forms that ACTUALLY hit the evaluator at
          # render time. Anything the user writes inside `{{ … }}` that
          # is NOT an `inputs.*` reference lands in the evaluator.
          substituted = substitute_sample_inputs(yaml)

          {:ok, blueprint_or_binding} = parse_yaml(path, substituted)

          path
          |> collect_expressions(blueprint_or_binding)
          |> Enum.map(fn expr -> {path, expr, Evaluator.parse(expr)} end)
        end)

      failures =
        Enum.filter(results, fn
          {_, _, {:ok, _}} -> false
          _ -> true
        end)

      assert failures == [],
             """
             The evaluator rejected expressions from shipped blueprints.
             The whitelist in `Loupey.Bindings.Expression.Evaluator` does
             not cover the grammar in use. Either widen the whitelist
             (with care — security boundary) or fix the blueprint.

             #{Enum.map_join(failures, "\n\n", &format_failure/1)}
             """
    end
  end

  # ---------------------------------------------------------------------------

  defp parse_yaml(path, contents) do
    alias Loupey.Bindings.YamlParser

    if String.contains?(Path.basename(path), "binding") do
      YamlParser.parse_binding(contents)
    else
      YamlParser.parse_blueprint(contents)
    end
  end

  # Sample inputs for `{{ inputs.X }}` substitution. Covers every input
  # name referenced in any shipped blueprint. If a new blueprint adds an
  # unrecognized input, it'll substitute as-is ({{ inputs.X }}) and the
  # evaluator will trip on the unresolved template — catch it here.
  @sample_inputs %{
    "entity" => "light.living_room",
    "color" => "#FFD700",
    "on_color" => "#FFD700",
    "off_color" => "#333333",
    "fill_color" => "#FFD700",
    "on_icon" => "light/on.png",
    "off_icon" => "light/off.png",
    "label" => "Layout",
    "layout" => "main",
    "unit" => "°F",
    "step" => "10"
  }

  defp substitute_sample_inputs(yaml) do
    Enum.reduce(@sample_inputs, yaml, fn {key, value}, acc ->
      String.replace(acc, "{{ inputs.#{key} }}", to_string(value))
    end)
  end

  # Walk a parsed blueprint/binding and return every bare expression
  # string the evaluator would see. For `when:` that's the string itself;
  # for templates it's each `{{ … }}` body.
  defp collect_expressions(_path, blueprint_or_binding) do
    input_rules = Map.get(blueprint_or_binding, :input_rules, [])
    output_rules = Map.get(blueprint_or_binding, :output_rules, [])

    input_rule_exprs =
      input_rules
      |> Enum.flat_map(fn rule ->
        when_exprs =
          case rule.when do
            nil ->
              []

            true ->
              []

            expr when is_binary(expr) ->
              # Shipped blueprints use both bare (`when: 'state == "playing"'`)
              # and braced (`when: "{{ state == \"on\" }}"`) forms for input-
              # rule conditions — same as output rules. Collect both.
              [strip_template_braces(expr) | extract_template_exprs(expr)]
          end

        action_exprs =
          rule.actions
          |> Enum.flat_map(&extract_template_exprs_from_map/1)

        when_exprs ++ action_exprs
      end)

    output_rule_exprs =
      output_rules
      |> Enum.flat_map(fn rule ->
        when_exprs =
          case rule.when do
            true ->
              []

            expr when is_binary(expr) ->
              [strip_template_braces(expr) | extract_template_exprs(expr)]
          end

        instr_exprs = extract_template_exprs_from_map(rule.instructions)
        when_exprs ++ instr_exprs
      end)

    (input_rule_exprs ++ output_rule_exprs)
    |> Enum.uniq()
    |> Enum.reject(&(&1 == "" or &1 == "true"))
  end

  # `when: 'state == "on"'` arrives as the raw expression string (no
  # `{{ … }}` wrapping), so strip templates and also take the bare form.
  defp strip_template_braces(str) do
    str
    |> String.replace(~r/\{\{\s*(.+?)\s*\}\}/, "\\1")
    |> String.trim()
  end

  defp extract_template_exprs(nil), do: []
  defp extract_template_exprs(true), do: []

  defp extract_template_exprs(str) when is_binary(str) do
    ~r/\{\{\s*(.+?)\s*\}\}/
    |> Regex.scan(str)
    |> Enum.map(fn [_, expr] -> String.trim(expr) end)
  end

  defp extract_template_exprs_from_map(%{} = map) do
    Enum.flat_map(map, fn {_k, v} -> extract_template_exprs_from_value(v) end)
  end

  defp extract_template_exprs_from_map(_), do: []

  defp extract_template_exprs_from_value(v) when is_binary(v), do: extract_template_exprs(v)
  defp extract_template_exprs_from_value(%{} = m), do: extract_template_exprs_from_map(m)

  defp extract_template_exprs_from_value(list) when is_list(list),
    do: Enum.flat_map(list, &extract_template_exprs_from_value/1)

  defp extract_template_exprs_from_value(_), do: []

  defp format_failure({path, expr, error}) do
    """
    #{Path.relative_to_cwd(path)}
      expression: #{inspect(expr)}
      evaluator returned: #{inspect(error)}
    """
  end
end
