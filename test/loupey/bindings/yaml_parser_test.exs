defmodule Loupey.Bindings.YamlParserTest do
  use ExUnit.Case, async: true

  alias Loupey.Bindings.YamlParser

  describe "parse_binding/1" do
    test "parses a basic binding with input and output rules" do
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
      assert input_rule.action == "call_service"
      assert input_rule.params.domain == "light"
      assert input_rule.params.target == "{{ entity_id }}"

      [on_rule, off_rule] = binding.output_rules
      assert on_rule.instructions.icon == "light/on.png"
      assert off_rule.instructions.color == "#333333"
    end

    test "parses binding with when conditions on input rules" do
      yaml = """
      entity_id: "media_player.tv"
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
    end

    test "parses layout switch binding" do
      yaml = """
      input_rules:
        - on: press
          action: switch_layout
          layout: "media"
      output_rules: []
      """

      assert {:ok, binding} = YamlParser.parse_binding(yaml)
      assert binding.entity_id == nil

      [rule] = binding.input_rules
      assert rule.action == "switch_layout"
      assert rule.params.layout == "media"
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
      assert input_rule.params.target == "light.living_room"

      [on_rule, off_rule] = binding.output_rules
      assert on_rule.instructions.color == "#FF0000"
      assert off_rule.instructions.color == "#333333"
    end
  end
end
