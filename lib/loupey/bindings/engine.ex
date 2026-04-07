defmodule Loupey.Bindings.Engine do
  @moduledoc """
  GenServer that connects device input events to HA actions and
  HA state changes to device rendering.

  This is the central hub — it subscribes to both device events and HA state
  changes, delegates to the pure functional core (Rules, LayoutEngine) for
  all decisions, and sends the resulting commands to the appropriate targets.

  One Engine per active device.
  """

  use GenServer
  require Logger

  alias Loupey.Bindings.{Expression, LayoutEngine, Profile, Rules}
  alias Loupey.Device.{Control, Spec}
  alias Loupey.DeviceServer
  alias Loupey.Events.TouchEvent
  alias Loupey.HA
  alias Loupey.HA.ServiceCall

  @touch_move_debounce_ms 400

  defmodule State do
    @moduledoc false
    defstruct [
      :device_id,
      :spec,
      :profile,
      entity_states: %{},
      last_touch_move_at: 0,
      pending_touch_move: nil
    ]
  end

  # -- Public API --

  @doc """
  Start a binding engine for a device.

  The engine loads the active profile from the database on init,
  so it always has the current state — even after a crash restart.
  An optional `:profile` can be passed to skip the DB lookup on first start.
  """
  def start_link(opts) do
    device_id = Keyword.fetch!(opts, :device_id)
    GenServer.start_link(__MODULE__, {device_id, opts[:profile]}, name: via_tuple(device_id))
  end

  @doc """
  Update the profile (e.g., after editing layouts in the UI).
  Triggers a full re-render of the active layout.
  """
  def update_profile(device_id, %Profile{} = profile) do
    GenServer.cast(via_tuple(device_id), {:update_profile, profile})
  end

  @doc """
  Switch to a different layout by name.
  """
  def switch_layout(device_id, layout_id) do
    GenServer.cast(via_tuple(device_id), {:switch_layout, layout_id})
  end

  defp via_tuple(device_id) do
    {:via, Registry, {Loupey.DeviceRegistry, {:engine, device_id}}}
  end

  # -- GenServer callbacks --

  @impl true
  def init({device_id, initial_profile}) do
    spec = DeviceServer.get_spec(device_id)

    # Subscribe to device input events
    Loupey.Devices.subscribe(device_id)

    # Load profile: use provided profile, or load from DB (for crash recovery)
    profile = initial_profile || load_profile_from_db()

    {entity_states, profile} =
      if profile do
        entity_ids = collect_entity_ids(profile)
        {subscribe_and_fetch(entity_ids), profile}
      else
        {%{}, nil}
      end

    state = %State{
      device_id: device_id,
      spec: spec,
      profile: profile,
      entity_states: entity_states
    }

    # Initial render of active layout (if we have a profile)
    if profile, do: send(self(), :render_active_layout)

    {:ok, state}
  end

  @impl true
  def handle_info(:render_active_layout, state) do
    render_active_layout(state)
    {:noreply, state}
  end

  # Device input event
  def handle_info({:device_event, _device_id, event}, state) do
    state = handle_device_event(event, state)
    {:noreply, state}
  end

  # HA state change
  def handle_info({:ha_state_changed, entity_id, new_state, _old_state}, state) do
    state = handle_state_change(entity_id, new_state, state)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_cast({:switch_layout, layout_id}, state) do
    state = do_switch_layout(state, layout_id)
    {:noreply, state}
  end

  def handle_cast({:update_profile, profile}, state) do
    entity_ids = collect_entity_ids(profile)
    new_entity_states = subscribe_and_fetch(entity_ids)
    entity_states = Map.merge(state.entity_states, new_entity_states)

    state = %{state | profile: profile, entity_states: entity_states}

    # Clear all controls first to remove stale content from deleted bindings
    clear_commands = LayoutEngine.clear_all(state.spec)
    send_commands(state.device_id, clear_commands, state.spec)

    render_active_layout(state)
    {:noreply, state}
  end

  # -- Event handling --

  defp handle_device_event(event, state) do
    # Flush any pending throttled touch_move call on touch_end
    state = maybe_flush_pending_touch(event, state)

    layout = get_active_layout(state)

    if layout do
      control_id = event_control_id(event)
      control = Spec.find_control(state.spec, control_id)
      bindings = Map.get(layout.bindings, control_id, [])

      Enum.reduce(bindings, state, fn binding, acc ->
        process_binding_input(binding, event, acc, control)
      end)
    else
      state
    end
  end

  defp maybe_flush_pending_touch(%TouchEvent{action: :end}, %{pending_touch_move: params} = state)
       when not is_nil(params) do
    execute_service_call(params)
    %{state | pending_touch_move: nil, last_touch_move_at: System.monotonic_time(:millisecond)}
  end

  defp maybe_flush_pending_touch(_event, state), do: state

  defp process_binding_input(binding, event, state, control) do
    # For backward compat: if binding has entity_id, pass its state
    entity_state =
      if binding.entity_id, do: Map.get(state.entity_states, binding.entity_id)

    case Rules.match_input(event, binding, entity_state, control) do
      {:actions, action_list} ->
        Enum.reduce(action_list, state, &execute_action(&1, event, &2))

      :no_match ->
        state
    end
  end

  defp execute_action(%{action: "switch_layout", layout: layout_id}, _event, state) do
    do_switch_layout_async(state.device_id, to_string(layout_id))
    state
  end

  defp execute_action(%{action: "call_service"} = params, event, state) do
    if touch_move?(event) do
      debounce_touch_move(params, state)
    else
      execute_service_call(params)
      state
    end
  end

  defp execute_action(_action, _event, state), do: state

  defp touch_move?(%TouchEvent{action: :move}), do: true
  defp touch_move?(_), do: false

  defp debounce_touch_move(params, state) do
    now = System.monotonic_time(:millisecond)
    elapsed = now - state.last_touch_move_at

    if elapsed >= @touch_move_debounce_ms do
      execute_service_call(params)
      %{state | last_touch_move_at: now, pending_touch_move: nil}
    else
      # Stash the latest params — will be sent on the next move that
      # passes the throttle window, or on touch_end
      %{state | pending_touch_move: params}
    end
  end

  defp handle_state_change(entity_id, new_state, state) do
    entity_states = Map.put(state.entity_states, entity_id, new_state)
    state = %{state | entity_states: entity_states}

    layout = get_active_layout(state)

    if layout do
      commands = LayoutEngine.render_for_entity(layout, entity_id, new_state, state.spec)
      send_commands(state.device_id, commands, state.spec)
    end

    state
  end

  defp do_switch_layout(state, layout_id) do
    # Clear all controls first
    clear_commands = LayoutEngine.clear_all(state.spec)
    send_commands(state.device_id, clear_commands, state.spec)

    {profile, commands} =
      LayoutEngine.switch_layout(state.profile, layout_id, state.entity_states, state.spec)

    send_commands(state.device_id, commands, state.spec)
    %{state | profile: profile}
  end

  defp do_switch_layout_async(device_id, layout_id) do
    GenServer.cast(via_tuple(device_id), {:switch_layout, layout_id})
  end

  # -- Helpers --

  defp get_active_layout(%State{profile: nil}), do: nil

  defp get_active_layout(%State{profile: profile}) do
    Map.get(profile.layouts, profile.active_layout)
  end

  defp render_active_layout(state) do
    layout = get_active_layout(state)

    if layout do
      commands = LayoutEngine.render_layout(layout, state.entity_states, state.spec)
      send_commands(state.device_id, commands, state.spec)
    end
  end

  defp send_commands(device_id, commands, spec) do
    display_ids =
      spec.controls
      |> Enum.filter(&Control.has_capability?(&1, :display))
      |> Enum.map(& &1.display.display_id)
      |> Enum.uniq()

    Enum.each(commands, &DeviceServer.render(device_id, &1))

    Enum.each(display_ids, &DeviceServer.refresh(device_id, &1))
  end

  defp event_control_id(%{control_id: id}), do: id

  defp execute_service_call(params) do
    domain = Map.get(params, :domain) || Map.get(params, "domain")
    service = Map.get(params, :service) || Map.get(params, "service")
    target = Map.get(params, :target) || Map.get(params, "target")

    if domain && service do
      HA.call_service(%ServiceCall{
        domain: domain,
        service: service,
        target: format_target(target),
        service_data: Map.get(params, :service_data, %{})
      })
    end
  end

  defp format_target(target) when is_binary(target), do: %{entity_id: target}
  defp format_target(target) when is_map(target), do: target
  defp format_target(_), do: nil

  defp collect_entity_ids(%Profile{layouts: layouts}) do
    all_bindings =
      layouts
      |> Map.values()
      |> Enum.flat_map(fn layout -> layout.bindings |> Map.values() |> List.flatten() end)

    # From binding entity_id (backward compat)
    binding_entities = all_bindings |> Enum.map(& &1.entity_id) |> Enum.reject(&is_nil/1)

    # From input rule action targets
    action_targets =
      all_bindings
      |> Enum.flat_map(& &1.input_rules)
      |> Enum.flat_map(& &1.actions)
      |> Enum.map(&Map.get(&1, :target))
      |> Enum.reject(&is_nil/1)
      |> Enum.filter(&is_binary/1)

    # From state_of()/attr_of() in expressions (output rules + input rule conditions)
    expression_entities =
      all_bindings
      |> Enum.flat_map(&extract_expression_entities/1)

    (binding_entities ++ action_targets ++ expression_entities)
    |> Enum.uniq()
  end

  defp extract_expression_entities(binding) do
    output_exprs =
      binding.output_rules
      |> Enum.flat_map(fn rule ->
        when_refs = extract_refs_from_when(rule.when)
        instr_refs = extract_refs_from_instructions(rule.instructions)
        when_refs ++ instr_refs
      end)

    input_exprs =
      binding.input_rules
      |> Enum.flat_map(fn rule ->
        extract_refs_from_when(rule.when)
      end)

    output_exprs ++ input_exprs
  end

  defp extract_refs_from_when(nil), do: []
  defp extract_refs_from_when(true), do: []
  defp extract_refs_from_when(expr) when is_binary(expr), do: Expression.extract_entity_refs(expr)

  defp extract_refs_from_instructions(instructions) when is_map(instructions) do
    instructions
    |> Map.values()
    |> Enum.flat_map(&extract_refs_from_value/1)
  end

  defp extract_refs_from_instructions(_), do: []

  defp extract_refs_from_value(value) when is_binary(value), do: Expression.extract_entity_refs(value)
  defp extract_refs_from_value(%{} = map), do: map |> Map.values() |> Enum.flat_map(&extract_refs_from_value/1)
  defp extract_refs_from_value(_), do: []

  defp subscribe_and_fetch(entity_ids) do
    Map.new(entity_ids, fn entity_id ->
      HA.subscribe(entity_id)
      state = HA.get_state(entity_id)
      {entity_id, state}
    end)
  end

  defp load_profile_from_db do
    case Loupey.Profiles.get_active_profile() do
      nil -> nil
      db_profile -> Loupey.Profiles.to_core_profile(db_profile)
    end
  end
end
