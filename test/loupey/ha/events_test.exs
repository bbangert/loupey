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

  describe ":disconnected and unknown messages" do
    test "disconnected message is accepted without crashing", %{events: events} do
      ref = Process.monitor(events)
      send(events, {:hassock_cache, self(), :disconnected})
      refute_receive {:DOWN, ^ref, :process, ^events, _}, 200
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
