defmodule Loupey.Bindings.YamlParserTest do
  use ExUnit.Case, async: true

  alias Loupey.Bindings.YamlParser

  describe "parse_binding/1 — old single-action format (backward compat)" do
    test "parses single action into actions list" do
      yaml = """
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
      """

      assert {:ok, binding} = YamlParser.parse_binding(yaml)
      assert binding.entity_id == "light.living_room"
      assert length(binding.input_rules) == 1
      assert length(binding.output_rules) == 2

      [input_rule] = binding.input_rules
      assert input_rule.on == :press
      assert [action] = input_rule.actions
      assert action.action == "call_service"
      assert action.domain == "light"
      assert action.target == "{{ entity_id }}"

      [on_rule, off_rule] = binding.output_rules
      assert on_rule.instructions.icon == "light/on.png"
      assert off_rule.instructions.color == "#333333"
    end

    test "parses when conditions on input rules" do
      yaml = """
      input_rules:
        - on: press
          when: "{{ state == 'playing' }}"
          action: call_service
          domain: media_player
          service: media_pause
        - on: press
          when: "{{ state == 'paused' }}"
          action: call_service
          domain: media_player
          service: media_play
      output_rules: []
      """

      assert {:ok, binding} = YamlParser.parse_binding(yaml)
      assert length(binding.input_rules) == 2

      [pause_rule, play_rule] = binding.input_rules
      assert pause_rule.when == "{{ state == 'playing' }}"
      assert play_rule.when == "{{ state == 'paused' }}"
      assert [%{service: "media_pause"}] = pause_rule.actions
      assert [%{service: "media_play"}] = play_rule.actions
    end

    test "parses layout switch" do
      yaml = """
      input_rules:
        - on: press
          action: switch_layout
          layout: "media"
      output_rules: []
      """

      assert {:ok, binding} = YamlParser.parse_binding(yaml)
      [rule] = binding.input_rules
      assert [%{action: "switch_layout", layout: "media"}] = rule.actions
    end
  end

  describe "parse_binding/1 — new actions list format" do
    test "parses multiple actions per rule" do
      yaml = """
      input_rules:
        - on: press
          actions:
            - action: call_service
              domain: light
              service: toggle
              target: "light.office"
            - action: call_service
              domain: media_player
              service: media_pause
              target: "media_player.tv"
      output_rules: []
      """

      assert {:ok, binding} = YamlParser.parse_binding(yaml)
      [rule] = binding.input_rules
      assert length(rule.actions) == 2
      [first, second] = rule.actions
      assert first.action == "call_service"
      assert first.target == "light.office"
      assert second.service == "media_pause"
    end
  end

  describe "parse_blueprint/1" do
    test "parses a blueprint with inputs" do
      yaml = """
      name: "Light Toggle"
      description: "Button that toggles a light"
      inputs:
        entity:
          type: entity
          domain: light
          description: "The light to control"
        on_color:
          type: color
          default: "#FFD700"
          description: "Color when on"
      input_rules:
        - on: press
          action: call_service
          domain: light
          service: toggle
          target: "{{ inputs.entity }}"
      output_rules:
        - when: "{{ state == 'on' }}"
          color: "{{ inputs.on_color }}"
        - when: "{{ state == 'off' }}"
          color: "#333333"
      """

      assert {:ok, blueprint} = YamlParser.parse_blueprint(yaml)
      assert blueprint.name == "Light Toggle"
      assert blueprint.inputs["entity"].type == "entity"
      assert blueprint.inputs["on_color"].default == "#FFD700"
      assert length(blueprint.input_rules) == 1
      assert length(blueprint.output_rules) == 2
    end
  end

  describe "instantiate_blueprint/2" do
    test "resolves input references in rules" do
      yaml = """
      name: "Light Toggle"
      inputs:
        entity:
          type: entity
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
        - when: "{{ state == 'off' }}"
          color: "#333333"
      """

      {:ok, blueprint} = YamlParser.parse_blueprint(yaml)

      binding =
        YamlParser.instantiate_blueprint(blueprint, %{
          "entity" => "light.living_room",
          "on_color" => "#FF0000"
        })

      assert binding.entity_id == "light.living_room"

      [input_rule] = binding.input_rules
      assert [%{target: "light.living_room"}] = input_rule.actions

      [on_rule, off_rule] = binding.output_rules
      assert on_rule.instructions.color == "#FF0000"
      assert off_rule.instructions.color == "#333333"
    end
  end
end
