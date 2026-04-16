defmodule Loupey.HA.IntegrationTest do
  @moduledoc """
  Integration test against a live Home Assistant instance.

  Run with: mix test --include ha_integration test/loupey/ha/integration_test.exs

  Requires environment variables:
  - HA_URL — e.g., "http://homeassistant.local:8123"
  - HA_TOKEN — a long-lived access token

  This test:
  1. Connects to HA and authenticates
  2. Verifies initial state load (all entities cached)
  3. Lists entities by domain
  4. Subscribes to state changes and toggles a light (if one exists)
  5. Calls a service
  """

  use ExUnit.Case

  alias Hassock.{Config, ServiceCall}
  alias Loupey.HA
  alias Loupey.HA.Events

  @moduletag :ha_integration
  @state_timeout_ms 10_000

  setup_all do
    url = System.get_env("HA_URL")
    token = System.get_env("HA_TOKEN")

    if is_nil(url) or is_nil(token) do
      IO.puts("\n  HA_URL and HA_TOKEN not set — skipping HA integration tests")
      %{skip: true}
    else
      config = %Config{url: url, token: token}
      {:ok, _pid} = HA.connect(config)

      # Wait for initial state load
      :ok = Events.subscribe_connected()

      receive do
        :ha_connected -> :ok
      after
        @state_timeout_ms ->
          flunk("Timed out waiting for HA connection")
      end

      light_entity = System.get_env("HA_LIGHT_ENTITY")
      %{config: config, light_entity: light_entity}
    end
  end

  setup context do
    if context[:skip], do: :ignore, else: :ok
  end

  describe "connection and state" do
    test "loads entities into state cache" do
      states = HA.get_all_states()
      assert states != []
      IO.puts("\n  Loaded #{length(states)} entities from HA")
    end

    test "can query entities by domain" do
      all = HA.get_all_states()

      domains =
        all
        |> Enum.map(fn s -> s.entity_id |> String.split(".") |> hd() end)
        |> Enum.frequencies()
        |> Enum.sort_by(fn {_d, count} -> -count end)

      IO.puts("\n  Entity domains:")

      for {domain, count} <- Enum.take(domains, 10) do
        IO.puts("    #{domain}: #{count}")
      end

      # Verify get_domain works
      if Enum.any?(domains, fn {d, _} -> d == "light" end) do
        lights = HA.get_domain("light")
        assert lights != []
        IO.puts("  Sample light: #{hd(lights).entity_id} = #{hd(lights).state}")
      end
    end

    test "can look up a specific entity" do
      states = HA.get_all_states()
      first = hd(states)
      fetched = HA.get_state(first.entity_id)
      assert fetched != nil
      assert fetched.entity_id == first.entity_id
    end
  end

  describe "state subscriptions" do
    test "receives state_changed events when an entity changes", %{light_entity: light_entity} do
      target =
        if light_entity do
          HA.get_state(light_entity)
        else
          HA.get_domain("light") |> List.first()
        end

      if is_nil(target) do
        IO.puts("\n  No lights found — set HA_LIGHT_ENTITY or add a light to HA")
      else
        :ok = HA.subscribe(target.entity_id)

        IO.puts("\n  Toggling #{target.entity_id} (currently #{target.state})...")

        HA.call_service(%ServiceCall{
          domain: "light",
          service: "toggle",
          target: %{entity_id: target.entity_id}
        })

        assert_receive {:ha_state_changed, entity_id, new_state, _old_state}, @state_timeout_ms
        assert entity_id == target.entity_id
        IO.puts("  State changed to: #{new_state.state}")

        # Toggle back
        Process.sleep(500)

        HA.call_service(%ServiceCall{
          domain: "light",
          service: "toggle",
          target: %{entity_id: target.entity_id}
        })

        assert_receive {:ha_state_changed, ^entity_id, restored_state, _}, @state_timeout_ms
        IO.puts("  Restored to: #{restored_state.state}")
      end
    end
  end

  describe "service calls" do
    test "can call a service without error" do
      # Call a safe, read-only-ish service — homeassistant.check_config
      # or just verify the call doesn't crash
      switches = HA.get_domain("input_boolean")

      if switches == [] do
        IO.puts("\n  No input_boolean entities — skipping service call test")
      else
        target = hd(switches)
        IO.puts("\n  Toggling input_boolean: #{target.entity_id}")

        :ok = HA.subscribe(target.entity_id)

        HA.call_service(%ServiceCall{
          domain: "input_boolean",
          service: "toggle",
          target: %{entity_id: target.entity_id}
        })

        assert_receive {:ha_state_changed, _, _, _}, @state_timeout_ms

        # Toggle back
        Process.sleep(300)

        HA.call_service(%ServiceCall{
          domain: "input_boolean",
          service: "toggle",
          target: %{entity_id: target.entity_id}
        })

        assert_receive {:ha_state_changed, _, _, _}, @state_timeout_ms
      end
    end
  end
end
