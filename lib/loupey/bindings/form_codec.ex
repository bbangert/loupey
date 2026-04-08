defmodule Loupey.Bindings.FormCodec do
  @moduledoc """
  Encodes and decodes binding form data to/from YAML strings.

  This module handles the UI form representation — plain maps with string
  values used by `BindingFormComponent`. It is distinct from `YamlParser`,
  which produces runtime structs (`%Binding{}`, `%InputRule{}`, etc.).
  """

  # -- Encode (form data -> YAML string) --

  @doc """
  Encode form data and an optional entity_id into a YAML string.

  Single-action input rules use the inline format (action fields on the rule
  itself) for backward compatibility. Multi-action rules use an `actions` list.
  """
  @spec encode(map(), String.t() | nil) :: String.t()
  def encode(form_data, entity_id) do
    doc =
      %{}
      |> put_if_present("entity_id", entity_id)
      |> Map.put("input_rules", encode_input_rules(form_data.input_rules))
      |> Map.put("output_rules", encode_output_rules(form_data.output_rules))

    Ymlr.document!(doc)
  end

  defp encode_input_rules(rules), do: Enum.map(rules, &encode_input_rule/1)

  defp encode_input_rule(rule) do
    base =
      %{"on" => to_string(rule[:on] || rule.on)}
      |> put_when(rule[:when])

    case rule[:actions] || [] do
      [single] -> Map.merge(base, encode_action(single))
      actions -> Map.put(base, "actions", Enum.map(actions, &encode_action/1))
    end
  end

  defp encode_action(action) do
    type = to_string(action[:action])

    base = %{"action" => type}

    base =
      if type == "call_service" do
        base
        |> put_if_present("domain", action[:domain])
        |> put_if_present("service", action[:service])
        |> put_if_present("target", action[:target])
        |> put_if_present_map("service_data", action[:service_data])
      else
        base
      end

    if type == "switch_layout" do
      put_if_present(base, "layout", action[:layout])
    else
      base
    end
  end

  defp encode_output_rules(rules), do: Enum.map(rules, &encode_output_rule/1)

  defp encode_output_rule(rule) do
    %{"when" => encode_when(rule[:when])}
    |> put_if_present("background", rule[:background])
    |> put_if_present("color", rule[:color])
    |> put_if_present("icon", rule[:icon])
    |> encode_fill(rule[:fill])
    |> encode_text(rule[:text])
  end

  defp encode_fill(map, %{} = fill) when map_size(fill) > 0 do
    encoded =
      %{}
      |> put_if_present("amount", fill[:amount])
      |> put_if_present("direction", fill[:direction])
      |> put_if_present("color", fill[:color])

    if encoded == %{}, do: map, else: Map.put(map, "fill", encoded)
  end

  defp encode_fill(map, _), do: map

  defp encode_text(map, %{content: content} = text) when is_binary(content) and content != "" do
    text_map =
      %{"content" => content}
      |> put_if_present("valign", text[:valign])
      |> put_if_present("font_size", text[:font_size])
      |> put_if_present("color", text[:color])

    Map.put(map, "text", text_map)
  end

  defp encode_text(map, _), do: map

  defp encode_when(true), do: true
  defp encode_when("true"), do: true
  defp encode_when(nil), do: true
  defp encode_when(expr), do: to_string(expr)

  defp put_when(map, nil), do: map
  defp put_when(map, ""), do: map
  defp put_when(map, val), do: Map.put(map, "when", to_string(val))

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, _key, ""), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, to_string(value))

  defp put_if_present_map(map, _key, nil), do: map
  defp put_if_present_map(map, _key, data) when data == %{}, do: map
  defp put_if_present_map(map, key, data) when is_map(data), do: Map.put(map, key, stringify_map(data))

  defp stringify_map(map), do: Map.new(map, fn {k, v} -> {to_string(k), to_string(v)} end)

  # -- Decode (YAML string -> form data) --

  @doc """
  Decode a YAML string into form data (map with `:input_rules` and `:output_rules`).
  """
  @spec decode(String.t() | nil) :: %{input_rules: list(), output_rules: list()}
  def decode(yaml) when yaml in ["", nil] do
    %{input_rules: [], output_rules: []}
  end

  def decode(yaml) do
    case YamlElixir.read_from_string(yaml) do
      {:ok, data} ->
        %{
          input_rules: decode_input_rules(data["input_rules"] || []),
          output_rules: decode_output_rules(data["output_rules"] || [])
        }

      _ ->
        %{input_rules: [], output_rules: []}
    end
  end

  defp decode_input_rules(rules), do: Enum.map(rules, &decode_input_rule/1)

  defp decode_input_rule(rule) do
    %{
      on: to_string(rule["on"] || "press"),
      when: decode_when_value(rule["when"]),
      actions: decode_rule_actions(rule)
    }
  end

  defp decode_rule_actions(%{"actions" => actions}) when is_list(actions) do
    Enum.map(actions, &decode_action/1)
  end

  defp decode_rule_actions(%{"action" => _} = rule), do: [decode_action(rule)]
  defp decode_rule_actions(_), do: []

  defp decode_action(action) do
    base = %{
      action: to_string(action["action"] || "call_service"),
      domain: to_string(action["domain"] || ""),
      service: to_string(action["service"] || ""),
      target: to_string(action["target"] || ""),
      layout: to_string(action["layout"] || "")
    }

    if is_map(action["service_data"]) and action["service_data"] != %{},
      do: Map.put(base, :service_data, stringify_map(action["service_data"])),
      else: base
  end

  defp decode_when_value(nil), do: nil
  defp decode_when_value(true), do: "true"
  defp decode_when_value(val), do: to_string(val)

  defp decode_output_rules(rules), do: Enum.map(rules, &decode_output_rule/1)

  defp decode_output_rule(rule) do
    when_val = rule["when"]
    when_str = if when_val == true or is_nil(when_val), do: "true", else: to_string(when_val)

    %{when: when_str}
    |> maybe_put(:background, rule["background"])
    |> maybe_put(:color, rule["color"])
    |> maybe_put(:icon, rule["icon"])
    |> decode_fill(rule["fill"])
    |> decode_text(rule["text"])
  end

  defp decode_fill(base, %{} = fill) do
    parsed =
      %{}
      |> maybe_put(:amount, fill["amount"])
      |> maybe_put(:direction, fill["direction"])
      |> maybe_put(:color, fill["color"])

    if parsed != %{}, do: Map.put(base, :fill, parsed), else: base
  end

  defp decode_fill(base, _), do: base

  defp decode_text(base, %{} = text) do
    parsed =
      %{content: text["content"]}
      |> maybe_put(:valign, text["valign"])
      |> maybe_put(:font_size, text["font_size"])
      |> maybe_put(:color, text["color"])

    Map.put(base, :text, parsed)
  end

  defp decode_text(base, _), do: base

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
