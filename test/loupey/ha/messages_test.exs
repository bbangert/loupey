defmodule Loupey.HA.MessagesTest do
  use ExUnit.Case, async: true

  alias Loupey.HA.{Messages, EntityState, ServiceCall}

  describe "parse/1 — auth messages" do
    test "parses auth_required" do
      json = ~s({"type": "auth_required", "ha_version": "2024.1.0"})
      assert :auth_required = Messages.parse(json)
    end

    test "parses auth_ok" do
      json = ~s({"type": "auth_ok", "ha_version": "2024.1.0"})
      assert :auth_ok = Messages.parse(json)
    end

    test "parses auth_invalid with message" do
      json = ~s({"type": "auth_invalid", "message": "Invalid access token"})
      assert {:auth_invalid, "Invalid access token"} = Messages.parse(json)
    end

    test "parses auth_invalid without message" do
      json = ~s({"type": "auth_invalid"})
      assert {:auth_invalid, "unknown reason"} = Messages.parse(json)
    end
  end

  describe "parse/1 — state_changed events" do
    test "parses state_changed with new and old state" do
      json =
        Jason.encode!(%{
          type: "event",
          id: 1,
          event: %{
            event_type: "state_changed",
            data: %{
              entity_id: "light.living_room",
              new_state: %{
                state: "on",
                attributes: %{brightness: 255, color_mode: "brightness"},
                last_changed: "2024-01-01T00:00:00Z",
                last_updated: "2024-01-01T00:00:00Z"
              },
              old_state: %{
                state: "off",
                attributes: %{brightness: 0},
                last_changed: "2024-01-01T00:00:00Z"
              }
            }
          }
        })

      assert {:state_changed, 1, new_state, old_state} = Messages.parse(json)
      assert %EntityState{entity_id: "light.living_room", state: "on"} = new_state
      assert new_state.attributes["brightness"] == 255
      assert %EntityState{state: "off"} = old_state
    end

    test "parses state_changed with nil old_state" do
      json =
        Jason.encode!(%{
          type: "event",
          id: 5,
          event: %{
            event_type: "state_changed",
            data: %{
              entity_id: "sensor.temp",
              new_state: %{state: "72.5", attributes: %{unit_of_measurement: "°F"}}
            }
          }
        })

      assert {:state_changed, 5, new_state, nil} = Messages.parse(json)
      assert new_state.state == "72.5"
    end
  end

  describe "parse/1 — result messages" do
    test "parses success result" do
      json = ~s({"type": "result", "id": 3, "success": true, "result": null})
      assert {:result, 3, true, nil} = Messages.parse(json)
    end

    test "parses failure result" do
      json =
        Jason.encode!(%{
          type: "result",
          id: 4,
          success: false,
          result: nil
        })

      assert {:result, 4, false, nil} = Messages.parse(json)
    end

    test "parses get_states result as states list" do
      json =
        Jason.encode!(%{
          type: "result",
          id: 2,
          success: true,
          result: [
            %{entity_id: "light.a", state: "on", attributes: %{}},
            %{entity_id: "switch.b", state: "off", attributes: %{}}
          ]
        })

      assert {:states, 2, states} = Messages.parse(json)
      assert length(states) == 2
      assert %EntityState{entity_id: "light.a", state: "on"} = hd(states)
    end
  end

  describe "parse/1 — other events" do
    test "parses non-state_changed event" do
      json =
        Jason.encode!(%{
          type: "event",
          id: 10,
          event: %{event_type: "automation_triggered", data: %{}}
        })

      assert {:event, 10, "automation_triggered", _} = Messages.parse(json)
    end

    test "parses unknown message" do
      json = ~s({"type": "something_new", "data": "hello"})
      assert {:unknown, %{"type" => "something_new"}} = Messages.parse(json)
    end
  end

  describe "encode_auth/1" do
    test "encodes auth message" do
      json = Messages.encode_auth("my_token")
      decoded = Jason.decode!(json)
      assert decoded["type"] == "auth"
      assert decoded["access_token"] == "my_token"
    end
  end

  describe "encode_subscribe/2" do
    test "encodes subscribe with default event type" do
      json = Messages.encode_subscribe(1)
      decoded = Jason.decode!(json)
      assert decoded["id"] == 1
      assert decoded["type"] == "subscribe_events"
      assert decoded["event_type"] == "state_changed"
    end

    test "encodes subscribe with custom event type" do
      json = Messages.encode_subscribe(5, "automation_triggered")
      decoded = Jason.decode!(json)
      assert decoded["event_type"] == "automation_triggered"
    end
  end

  describe "encode_get_states/1" do
    test "encodes get_states message" do
      json = Messages.encode_get_states(2)
      decoded = Jason.decode!(json)
      assert decoded["id"] == 2
      assert decoded["type"] == "get_states"
    end
  end

  describe "encode_service_call/2" do
    test "encodes basic service call" do
      call = %ServiceCall{domain: "light", service: "toggle"}
      json = Messages.encode_service_call(3, call)
      decoded = Jason.decode!(json)

      assert decoded["id"] == 3
      assert decoded["type"] == "call_service"
      assert decoded["domain"] == "light"
      assert decoded["service"] == "toggle"
      refute Map.has_key?(decoded, "target")
      refute Map.has_key?(decoded, "service_data")
    end

    test "encodes service call with target and data" do
      call = %ServiceCall{
        domain: "light",
        service: "turn_on",
        target: %{entity_id: "light.living_room"},
        service_data: %{brightness: 128}
      }

      json = Messages.encode_service_call(4, call)
      decoded = Jason.decode!(json)

      assert decoded["target"]["entity_id"] == "light.living_room"
      assert decoded["service_data"]["brightness"] == 128
    end
  end

  describe "state_changed?/2" do
    test "returns true when old is nil" do
      new = %EntityState{entity_id: "light.a", state: "on"}
      assert Messages.state_changed?(nil, new)
    end

    test "returns true when state value changes" do
      old = %EntityState{entity_id: "light.a", state: "off"}
      new = %EntityState{entity_id: "light.a", state: "on"}
      assert Messages.state_changed?(old, new)
    end

    test "returns true when attributes change" do
      old = %EntityState{entity_id: "light.a", state: "on", attributes: %{"brightness" => 100}}
      new = %EntityState{entity_id: "light.a", state: "on", attributes: %{"brightness" => 200}}
      assert Messages.state_changed?(old, new)
    end

    test "returns false when nothing meaningful changed" do
      old = %EntityState{
        entity_id: "light.a",
        state: "on",
        attributes: %{"brightness" => 100},
        last_updated: "2024-01-01T00:00:00Z"
      }

      new = %EntityState{
        entity_id: "light.a",
        state: "on",
        attributes: %{"brightness" => 100},
        last_updated: "2024-01-01T00:01:00Z"
      }

      refute Messages.state_changed?(old, new)
    end
  end
end
