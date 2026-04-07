defmodule Loupey.Bindings.RulesTest do
  use ExUnit.Case, async: true

  alias Loupey.Bindings.{Binding, InputRule, OutputRule, Rules}
  alias Loupey.Events.{PressEvent, RotateEvent}
  alias Loupey.HA.EntityState

  defp light_on do
    %EntityState{entity_id: "light.lr", state: "on", attributes: %{"brightness" => 200}}
  end

  defp light_off do
    %EntityState{entity_id: "light.lr", state: "off", attributes: %{"brightness" => 0}}
  end

  defp media_playing do
    %EntityState{
      entity_id: "media_player.tv",
      state: "playing",
      attributes: %{"media_title" => "Song"}
    }
  end

  describe "match_input/3" do
    test "matches press trigger with single action" do
      binding = %Binding{
        input_rules: [
          %InputRule{on: :press, actions: [%{action: "call_service", domain: "light", service: "toggle"}]}
        ]
      }

      event = %PressEvent{control_id: {:key, 0}, action: :press}
      assert {:actions, [%{action: "call_service", domain: "light", service: "toggle"}]} = Rules.match_input(event, binding, nil)
    end

    test "matches press trigger with multiple actions" do
      binding = %Binding{
        input_rules: [
          %InputRule{on: :press, actions: [
            %{action: "call_service", domain: "light", service: "toggle", target: "light.lr"},
            %{action: "call_service", domain: "media_player", service: "media_pause", target: "media_player.tv"}
          ]}
        ]
      }

      event = %PressEvent{control_id: {:key, 0}, action: :press}
      assert {:actions, [first, second]} = Rules.match_input(event, binding, nil)
      assert first.service == "toggle"
      assert second.service == "media_pause"
    end

    test "does not match wrong trigger type" do
      binding = %Binding{
        input_rules: [%InputRule{on: :press, actions: [%{action: "call_service"}]}]
      }

      event = %PressEvent{control_id: {:key, 0}, action: :release}
      assert :no_match = Rules.match_input(event, binding, nil)
    end

    test "matches with when condition" do
      binding = %Binding{
        input_rules: [
          %InputRule{
            on: :press,
            when: ~s(state == "playing"),
            actions: [%{action: "call_service", domain: "media_player", service: "media_pause"}]
          },
          %InputRule{
            on: :press,
            when: ~s(state != "playing"),
            actions: [%{action: "call_service", domain: "media_player", service: "media_play"}]
          }
        ]
      }

      event = %PressEvent{control_id: {:key, 0}, action: :press}

      assert {:actions, [%{service: "media_pause"}]} = Rules.match_input(event, binding, media_playing())
      assert {:actions, [%{service: "media_play"}]} = Rules.match_input(event, binding, light_off())
    end

    test "matches rotate triggers" do
      binding = %Binding{
        input_rules: [
          %InputRule{on: :rotate_cw, actions: [%{action: "call_service", service: "volume_up"}]},
          %InputRule{on: :rotate_ccw, actions: [%{action: "call_service", service: "volume_down"}]}
        ]
      }

      cw = %RotateEvent{control_id: :knob_tl, direction: :cw}
      ccw = %RotateEvent{control_id: :knob_tl, direction: :ccw}

      assert {:actions, [%{service: "volume_up"}]} = Rules.match_input(cw, binding, nil)
      assert {:actions, [%{service: "volume_down"}]} = Rules.match_input(ccw, binding, nil)
    end

    test "matches switch_layout action" do
      binding = %Binding{
        input_rules: [
          %InputRule{on: :press, actions: [%{action: "switch_layout", layout: "media"}]}
        ]
      }

      event = %PressEvent{control_id: {:button, 0}, action: :press}
      assert {:actions, [%{action: "switch_layout", layout: "media"}]} = Rules.match_input(event, binding, nil)
    end

    test "resolves template expressions in action params" do
      binding = %Binding{
        entity_id: "light.lr",
        input_rules: [
          %InputRule{
            on: :press,
            actions: [%{action: "call_service", target: "{{ entity_id }}"}]
          }
        ]
      }

      event = %PressEvent{control_id: {:key, 0}, action: :press}
      assert {:actions, [%{target: "light.lr"}]} = Rules.match_input(event, binding, light_on())
    end

    test "returns no_match for empty rules" do
      binding = %Binding{input_rules: []}
      event = %PressEvent{control_id: {:key, 0}, action: :press}
      assert :no_match = Rules.match_input(event, binding, nil)
    end
  end

  describe "match_output/2" do
    test "matches first true condition" do
      binding = %Binding{
        output_rules: [
          %OutputRule{when: ~s(state == "on"), instructions: %{icon: "light/on.png", color: "#FFD700"}},
          %OutputRule{when: ~s(state == "off"), instructions: %{icon: "light/off.png", color: "#333333"}}
        ]
      }

      assert {:match, %{icon: "light/on.png", color: "#FFD700"}} = Rules.match_output(binding, light_on())
      assert {:match, %{icon: "light/off.png", color: "#333333"}} = Rules.match_output(binding, light_off())
    end

    test "unconditional rule (true) always matches" do
      binding = %Binding{
        output_rules: [
          %OutputRule{when: true, instructions: %{text: "always"}}
        ]
      }

      assert {:match, %{text: "always"}} = Rules.match_output(binding, nil)
    end

    test "resolves template expressions in instructions" do
      binding = %Binding{
        output_rules: [
          %OutputRule{
            when: true,
            instructions: %{text: "{{ state }}°F", color: "#FFFFFF"}
          }
        ]
      }

      entity = %EntityState{entity_id: "sensor.temp", state: "72.5"}
      assert {:match, %{text: "72.5°F"}} = Rules.match_output(binding, entity)
    end

    test "resolves fill amount from template" do
      binding = %Binding{
        output_rules: [
          %OutputRule{
            when: ~s(state == "on"),
            instructions: %{
              fill: %{
                amount: "{{ attributes[\"brightness\"] / 255 * 100 }}",
                direction: :to_top,
                color: "#FFD700"
              }
            }
          }
        ]
      }

      assert {:match, %{fill: %{amount: amount}}} = Rules.match_output(binding, light_on())
      assert_in_delta amount, 78.4, 0.1
    end

    test "returns no_match when no rules match" do
      binding = %Binding{
        output_rules: [
          %OutputRule{when: ~s(state == "unavailable"), instructions: %{color: "#FF0000"}}
        ]
      }

      assert :no_match = Rules.match_output(binding, light_on())
    end

    test "returns no_match for empty rules" do
      assert :no_match = Rules.match_output(%Binding{output_rules: []}, light_on())
    end
  end
end
