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

  alias Hassock.ServiceCall
  alias Loupey.Animation.Ticker
  alias Loupey.Bindings.{Expression, LayoutEngine, OutputRule, Profile, Rules}
  alias Loupey.Bindings.Expression.Evaluator
  alias Loupey.Device.{Control, Spec}
  alias Loupey.DeviceServer
  alias Loupey.Events.TouchEvent
  alias Loupey.HA

  @touch_move_debounce_ms 400

  defmodule State do
    @moduledoc false
    # `last_match` tracks the most recent output-rule match for each
    # `{control_id, binding_idx}`. Shape: `{:matched, rule_idx} | :no_match`.
    # The Engine uses it to detect rule transitions and decide when to
    # cancel/install Ticker animations vs. rely on the direct render path.
    #
    # `ticker_monitor` is the monitor reference for the per-device
    # Ticker process. On `{:DOWN, ...}` the Engine clears `last_match`
    # so the next state-change re-installs animations against the
    # restarted Ticker (which boots with empty animation state).
    defstruct [
      :device_id,
      :spec,
      :profile,
      :ticker_monitor,
      entity_states: %{},
      last_match: %{},
      last_touch_move_at: 0,
      pending_touch_move: nil
    ]
  end

  # Retry interval for finding a freshly-started Ticker pid in the
  # registry. The Orchestrator starts the Ticker right after the Engine,
  # but there's a small race window during boot (and on Ticker restart).
  @ticker_monitor_retry_ms 50

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

    # Subscribe to device input events — cheap, non-blocking PubSub.
    Loupey.Devices.subscribe(device_id)

    # Defer the expensive work (profile load from DB, HA-cache fetch for
    # every entity_id, initial render) to a self-send so init returns
    # immediately. Keeps supervisor startup non-blocking and lets
    # `DynamicSupervisor.start_child/2` return before HA subscriptions
    # settle.
    send(self(), {:init_state, initial_profile})

    # The Orchestrator starts the Ticker right after this Engine. We
    # can't `Process.monitor/1` it here — the registry entry isn't
    # there yet — so schedule a retry loop. `setup_ticker_monitor`
    # also re-fires after a `{:DOWN, ...}` to re-attach to the
    # restarted Ticker.
    send(self(), :setup_ticker_monitor)

    state = %State{
      device_id: device_id,
      spec: spec,
      profile: nil,
      entity_states: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_info({:init_state, initial_profile}, state) do
    case initial_profile || load_profile_from_db(state.spec.type) do
      nil ->
        {:noreply, state}

      profile ->
        entity_states = subscribe_and_fetch(collect_entity_ids(profile))
        state = %{state | profile: profile, entity_states: entity_states}
        send(self(), :render_active_layout)
        {:noreply, state}
    end
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

  # Ticker monitor — re-attach on every restart. Clears `last_match` so
  # the next dispatch sees the world as "no animations installed" and
  # re-installs them, rather than landing on the same-rule-same-idx no-op
  # against a Ticker that just lost its state.
  def handle_info(:setup_ticker_monitor, state) do
    {:noreply, attach_ticker_monitor(state)}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %State{ticker_monitor: ref} = state) do
    Process.send_after(self(), :setup_ticker_monitor, @ticker_monitor_retry_ms)
    {:noreply, %{state | ticker_monitor: nil, last_match: %{}}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp attach_ticker_monitor(state) do
    case Registry.lookup(Loupey.DeviceRegistry, {:ticker, state.device_id}) do
      [{pid, _}] ->
        ref = Process.monitor(pid)
        %{state | ticker_monitor: ref}

      [] ->
        Process.send_after(self(), :setup_ticker_monitor, @ticker_monitor_retry_ms)
        state
    end
  end

  @impl true
  def handle_cast({:switch_layout, layout_id}, state) do
    state = do_switch_layout(state, layout_id)
    {:noreply, state}
  end

  def handle_cast({:update_profile, profile}, state) do
    # New profile → some expression sources from the old profile may no
    # longer be referenced. Drop this process's evaluator AST cache so it
    # doesn't accumulate stale entries across repeated edits.
    Evaluator.clear_cache()

    # Diff old vs new entity ids: subscribe to added, unsubscribe from
    # removed, keep state for overlapping. Previously this unconditionally
    # merged a fresh subscribe_and_fetch onto the existing map — leaking
    # subscriptions (and keeping stale entity_states) for every entity
    # the user removed from a binding.
    old_ids = MapSet.new(Map.keys(state.entity_states))
    new_ids = MapSet.new(collect_entity_ids(profile))

    to_unsubscribe = MapSet.difference(old_ids, new_ids)
    to_subscribe = MapSet.difference(new_ids, old_ids)
    kept = MapSet.intersection(old_ids, new_ids)

    for entity_id <- to_unsubscribe, do: HA.unsubscribe(entity_id)

    added_states = subscribe_and_fetch(MapSet.to_list(to_subscribe))
    kept_states = Map.take(state.entity_states, MapSet.to_list(kept))
    entity_states = Map.merge(kept_states, added_states)

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
      dispatch_animations_for_entity(layout, entity_id, state)
    else
      state
    end
  end

  @doc false
  # Walks bindings affected by an entity-state change, compares each
  # binding's current rule match against its previous match, and routes
  # animation hand-offs (start/cancel) to the per-device Ticker as needed.
  # Returns the updated Engine state with `last_match` advanced.
  #
  # Public (with @doc false) so the engine_animation_test suite can drive
  # the dispatch logic with a real Ticker but without booting the full
  # Engine GenServer / DeviceServer stack.
  def dispatch_animations_for_entity(layout, entity_id, state) do
    Enum.reduce(layout.bindings, state, &dispatch_control(&1, entity_id, &2))
  end

  defp dispatch_control({control_id, control_bindings}, entity_id, state) do
    control_bindings
    |> Enum.with_index()
    |> Enum.reduce(state, &maybe_dispatch_binding(&1, entity_id, control_id, &2))
  end

  defp maybe_dispatch_binding({binding, idx}, entity_id, control_id, state) do
    if binding_references_entity?(binding, entity_id) do
      dispatch_binding(binding, idx, control_id, state)
    else
      state
    end
  end

  defp binding_references_entity?(binding, entity_id) do
    binding.entity_id == entity_id ||
      Enum.any?(binding.output_rules, &output_rule_references?(&1, entity_id))
  end

  defp output_rule_references?(rule, entity_id) do
    when_refs = if is_binary(rule.when), do: Expression.extract_entity_refs(rule.when), else: []
    when_refs == [entity_id] or entity_id in when_refs
  end

  defp dispatch_binding(binding, binding_idx, control_id, state) do
    entity_state = if binding.entity_id, do: Map.get(state.entity_states, binding.entity_id)
    match = Rules.match_output(binding, entity_state)
    key = {control_id, binding_idx}
    prev = Map.get(state.last_match, key, :no_match)

    apply_match_transition(state.device_id, control_id, prev, match)
    %{state | last_match: Map.put(state.last_match, key, match_summary(match))}
  end

  defp match_summary({:match, rule_idx, _rule, _instructions}), do: {:matched, rule_idx}
  defp match_summary(:no_match), do: :no_match

  defp apply_match_transition(_device_id, _control_id, :no_match, :no_match), do: :ok

  defp apply_match_transition(device_id, control_id, {:matched, _}, :no_match) do
    Ticker.cancel_all(device_id, control_id)
  end

  defp apply_match_transition(
         device_id,
         control_id,
         :no_match,
         {:match, _idx, rule, instructions}
       ) do
    install_rule_animations(device_id, control_id, rule, instructions)
  end

  defp apply_match_transition(
         device_id,
         control_id,
         {:matched, prev_idx},
         {:match, idx, rule, instructions}
       )
       when prev_idx != idx do
    Ticker.cancel_all(device_id, control_id)
    install_rule_animations(device_id, control_id, rule, instructions)
  end

  defp apply_match_transition(_device_id, _control_id, {:matched, _}, {:match, _, _, _}), do: :ok

  defp install_rule_animations(device_id, control_id, %OutputRule{} = rule, instructions) do
    Enum.each(rule.animations, fn kf ->
      Ticker.start_animation(device_id, control_id, :continuous, kf, instructions)
    end)

    Enum.each(rule.on_enter, fn kf ->
      Ticker.start_animation(device_id, control_id, :one_shot, kf, instructions)
    end)
  end

  defp do_switch_layout(state, layout_id) do
    cancel_all_animations(state)

    # Clear all controls first
    clear_commands = LayoutEngine.clear_all(state.spec)
    send_commands(state.device_id, clear_commands, state.spec)

    {profile, commands} =
      LayoutEngine.switch_layout(state.profile, layout_id, state.entity_states, state.spec)

    send_commands(state.device_id, commands, state.spec)
    %{state | profile: profile, last_match: %{}}
  end

  @doc false
  # Cancel every Ticker animation owned by this device. Used on layout
  # switches and profile reloads — the new layout's bindings will
  # re-install whatever animations they declare on first match.
  def cancel_all_animations(%State{device_id: device_id, last_match: last_match}) do
    last_match
    |> Map.keys()
    |> Enum.map(fn {control_id, _binding_idx} -> control_id end)
    |> Enum.uniq()
    |> Enum.each(&Ticker.cancel_all(device_id, &1))
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

  defp execute_service_call(%{domain: domain, service: service} = params)
       when is_binary(domain) and is_binary(service) do
    HA.call_service(%ServiceCall{
      domain: domain,
      service: service,
      target: format_target(Map.get(params, :target)),
      service_data: Map.get(params, :service_data, %{})
    })
  end

  defp execute_service_call(_params), do: :ok

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

  defp extract_refs_from_value(value) when is_binary(value),
    do: Expression.extract_entity_refs(value)

  defp extract_refs_from_value(%{} = map),
    do: map |> Map.values() |> Enum.flat_map(&extract_refs_from_value/1)

  defp extract_refs_from_value(_), do: []

  defp subscribe_and_fetch(entity_ids) do
    Map.new(entity_ids, fn entity_id ->
      HA.subscribe(entity_id)
      state = HA.get_state(entity_id)
      {entity_id, state}
    end)
  end

  defp load_profile_from_db(device_type) do
    case Loupey.Profiles.get_active_profile_for(device_type) do
      nil -> nil
      db_profile -> Loupey.Profiles.to_core_profile(db_profile)
    end
  end
end
