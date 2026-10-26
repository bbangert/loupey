defmodule Loupey.HA.EventsTest do
  use ExUnit.Case, async: true

  alias Hassock.EntityState
  alias Loupey.HA.Events

  setup do
    pubsub = :"pubsub_#{System.unique_integer([:positive])}"
    events_name = :"events_#{System.unique_integer([:positive])}"

    start_supervised!({Phoenix.PubSub, name: pubsub})
    {:ok, events} = start_supervised({Events, [name: events_name, pubsub: pubsub]})

    %{events: events, pubsub: pubsub}
  end

  describe ":ready" do
    test "broadcasts :ha_connected on the ha:connected topic", %{events: events, pubsub: pubsub} do
      :ok = Phoenix.PubSub.subscribe(pubsub, "ha:connected")

      send(events, {:hassock_cache, self(), :ready})

      assert_receive :ha_connected, 500
    end

    test "does not re-broadcast when the same cache re-syncs after a reconnect",
         %{events: events, pubsub: pubsub} do
      :ok = Phoenix.PubSub.subscribe(pubsub, "ha:connected")

      send(events, {:hassock_cache, self(), :ready})
      assert_receive :ha_connected, 500

      send(events, {:hassock_cache, self(), :disconnected})
      send(events, {:hassock_cache, self(), :ready})
      refute_receive :ha_connected, 200
    end

    test "broadcasts again for a new cache process", %{events: events, pubsub: pubsub} do
      :ok = Phoenix.PubSub.subscribe(pubsub, "ha:connected")

      send(events, {:hassock_cache, self(), :ready})
      assert_receive :ha_connected, 500

      new_cache = spawn(fn -> :ok end)
      send(events, {:hassock_cache, new_cache, :ready})
      assert_receive :ha_connected, 500
    end
  end

  describe "ready?/1" do
    test "is false until :ready, true after, false after :disconnected", %{events: events} do
      cache = spawn(fn -> Process.sleep(:infinity) end)
      refute Events.ready?(events)

      send(events, {:hassock_cache, cache, :ready})
      assert Events.ready?(events)

      send(events, {:hassock_cache, cache, :disconnected})
      refute Events.ready?(events)

      # The re-sync `:ready` after a reconnect isn't re-broadcast but does
      # mark the cache ready again.
      send(events, {:hassock_cache, cache, :ready})
      assert Events.ready?(events)
    end

    test "is false after an auth failure", %{events: events} do
      cache = spawn(fn -> Process.sleep(:infinity) end)
      send(events, {:hassock_cache, cache, :ready})
      assert Events.ready?(events)

      ExUnit.CaptureLog.capture_log(fn ->
        send(events, {:hassock_cache, cache, {:auth_failed, "Invalid access token"}})
        refute Events.ready?(events)
      end)
    end

    test "is false once the ready cache has exited", %{events: events} do
      cache = spawn(fn -> :ok end)
      ref = Process.monitor(cache)
      assert_receive {:DOWN, ^ref, :process, ^cache, _}

      send(events, {:hassock_cache, cache, :ready})
      refute Events.ready?(events)
    end

    test "broadcasts {:ha_ready, _} on every transition, including re-syncs",
         %{events: events, pubsub: pubsub} do
      :ok = Events.subscribe_status(pubsub)
      cache = spawn(fn -> Process.sleep(:infinity) end)

      send(events, {:hassock_cache, cache, :ready})
      assert_receive {:ha_ready, true}, 500

      # A second :ready while already ready is not a transition.
      send(events, {:hassock_cache, cache, :ready})
      refute_receive {:ha_ready, _}, 100

      send(events, {:hassock_cache, cache, :disconnected})
      assert_receive {:ha_ready, false}, 500

      send(events, {:hassock_cache, cache, :ready})
      assert_receive {:ha_ready, true}, 500
    end

    test "goes false and broadcasts when the ready cache exits",
         %{events: events, pubsub: pubsub} do
      :ok = Events.subscribe_status(pubsub)
      cache = spawn(fn -> Process.sleep(:infinity) end)

      send(events, {:hassock_cache, cache, :ready})
      assert_receive {:ha_ready, true}, 500

      Process.exit(cache, :kill)
      assert_receive {:ha_ready, false}, 500
      refute Events.ready?(events)
    end

    test "broadcasts not-ready when (re)started", %{pubsub: pubsub} do
      :ok = Events.subscribe_status(pubsub)
      name = :"events_restart_#{System.unique_integer([:positive])}"
      start_supervised!({Events, [name: name, pubsub: pubsub]}, id: name)
      assert_receive {:ha_ready, false}, 500
    end

    test "is false when the server isn't running" do
      refute Events.ready?(:"no_such_events_#{System.unique_integer([:positive])}")
    end
  end

  describe "{:changes, ...}" do
    test "broadcasts added entities with old_state=nil", %{events: events, pubsub: pubsub} do
      :ok = Phoenix.PubSub.subscribe(pubsub, "ha:state:light.kitchen")
      :ok = Phoenix.PubSub.subscribe(pubsub, "ha:state:all")

      new = entity("light.kitchen", "on")
      changes = %{added: [{"light.kitchen", new}], changed: [], removed: []}
      send(events, {:hassock_cache, self(), {:changes, changes}})

      assert_receive {:ha_state_changed, "light.kitchen", ^new, nil}, 500
      assert_receive {:ha_state_changed, "light.kitchen", ^new, nil}, 500
    end

    test "broadcasts changed entities with new and old state", %{events: events, pubsub: pubsub} do
      :ok = Phoenix.PubSub.subscribe(pubsub, "ha:state:light.office")
      :ok = Phoenix.PubSub.subscribe(pubsub, "ha:state:all")

      old = entity("light.office", "off")
      new = entity("light.office", "on")
      changes = %{added: [], changed: [{"light.office", new, old}], removed: []}
      send(events, {:hassock_cache, self(), {:changes, changes}})

      assert_receive {:ha_state_changed, "light.office", ^new, ^old}, 500
      assert_receive {:ha_state_changed, "light.office", ^new, ^old}, 500
    end

    test "does not broadcast to unrelated entity topics", %{events: events, pubsub: pubsub} do
      :ok = Phoenix.PubSub.subscribe(pubsub, "ha:state:switch.fan")

      new = entity("light.kitchen", "on")
      changes = %{added: [{"light.kitchen", new}], changed: [], removed: []}
      send(events, {:hassock_cache, self(), {:changes, changes}})

      refute_receive {:ha_state_changed, "switch.fan", _, _}, 200
    end
  end

  describe ":disconnected, :auth_failed and unknown messages" do
    test "disconnected message is accepted without crashing", %{events: events} do
      ref = Process.monitor(events)
      send(events, {:hassock_cache, self(), :disconnected})
      refute_receive {:DOWN, ^ref, :process, ^events, _}, 200
    end

    test "auth_failed is logged and broadcast", %{events: events, pubsub: pubsub} do
      :ok = Events.subscribe_auth_failed(pubsub)
      ref = Process.monitor(events)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          send(events, {:hassock_cache, self(), {:auth_failed, "Invalid access token"}})
          refute_receive {:DOWN, ^ref, :process, ^events, _}, 200
        end)

      assert log =~ "rejected the access token"
      assert_receive {:ha_auth_failed, "Invalid access token"}
    end

    test "unrelated messages fall through without crashing", %{events: events} do
      ref = Process.monitor(events)
      send(events, {:something_else, :whatever})
      refute_receive {:DOWN, ^ref, :process, ^events, _}, 200
    end
  end

  defp entity(entity_id, state) do
    %EntityState{entity_id: entity_id, state: state, attributes: %{}}
  end
end
