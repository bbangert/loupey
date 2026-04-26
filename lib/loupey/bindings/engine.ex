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
  alias Loupey.Animation.{Keyframes, Ticker}
  alias Loupey.Bindings.{Expression, InputRule, LayoutEngine, OutputRule, Profile, Rules}
  alias Loupey.Bindings.Expression.Evaluator
  alias Loupey.Device.{Control, Spec}
  alias Loupey.DeviceServer
  alias Loupey.Events.TouchEvent
  alias Loupey.HA

  @touch_move_debounce_ms 400

  defmodule State do
    @moduledoc false
    # `last_match` tracks the most recent output-rule match for each
    # `{control_id, binding_idx}`. Shape:
    # `{:matched, rule_idx, instructions} | :no_match`. The Engine
    # uses it to detect rule transitions (cancel/install animations)
    # and to diff the resolved instructions against the next match
    # for per-property `transitions` and `on_change` dispatch.
    # Non-animated rules (no animations / on_enter / transitions /
    # on_change) collapse to `:no_match` so non-animated rules don't
    # stomp animations installed by other bindings on the same control.
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
    state = dispatch_animations_for_active_layout(state)
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

  # Short-circuit when a monitor is already attached. Without this,
  # if the initial registry lookup misses, multiple
  # `Process.send_after/3` retries can be queued — and a `:DOWN`
  # path also schedules one. Once the Ticker comes up, each queued
  # message would call `Process.monitor/1` again, leaking refs.
  defp attach_ticker_monitor(%State{ticker_monitor: ref} = state) when not is_nil(ref) do
    state
  end

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

    # Cancel every Ticker animation owned by this device — bindings
    # the user just removed should not keep animating, and bindings
    # that survived will be re-installed by
    # `dispatch_animations_for_active_layout/1` below.
    cancel_all_animations(state)

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

    # Clearing `last_match` is what makes the Ticker re-install
    # animations on the next dispatch — without this, the old
    # last_match would short-circuit same-rule re-installs.
    state = %{state | profile: profile, entity_states: entity_states, last_match: %{}}

    # Clear all controls first to remove stale content from deleted bindings
    clear_commands = LayoutEngine.clear_all(state.spec)
    send_commands(state.device_id, clear_commands, state.spec)

    render_active_layout(state)
    state = dispatch_animations_for_active_layout(state)
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

      bindings
      |> Enum.with_index()
      |> Enum.reduce(state, fn {binding, idx}, acc ->
        process_binding_input(binding, idx, event, acc, control)
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

  defp process_binding_input(binding, binding_idx, event, state, control) do
    # For backward compat: if binding has entity_id, pass its state
    entity_state =
      if binding.entity_id, do: Map.get(state.entity_states, binding.entity_id)

    case Rules.match_input(event, binding, entity_state, control) do
      {:actions, rule, action_list} ->
        fire_input_animations(state, binding, binding_idx, event, rule)
        Enum.reduce(action_list, state, &execute_action(&1, event, &2))

      :no_match ->
        state
    end
  end

  # Input-rule animations fire as event one-shots on the touched
  # control — e.g. press flash on touch_start. The Ticker's public
  # API is `cast/2`, so a missing/dead Ticker is a silent no-op —
  # safe to call eagerly. We use `:event_one_shot` to distinguish
  # from output-rule on_enter for future stats / debug.
  defp fire_input_animations(_state, _binding, _idx, _event, %InputRule{animations: []}), do: :ok

  defp fire_input_animations(state, binding, binding_idx, event, %InputRule{animations: kfs}) do
    control_id = event_control_id(event)
    base = base_for_input_animation(state, binding, binding_idx)

    Enum.each(kfs, fn kf ->
      Ticker.start_animation(state.device_id, control_id, :event_one_shot, kf, base)
    end)
  end

  # The Ticker needs a base layer to render the animation over —
  # resolve from THIS binding (the one whose input rule fired), at
  # its actual `binding_idx`. Falls back to `%{}` if the binding
  # itself doesn't currently match an output rule, which is rare
  # since most bindings ship a `when: true` fallback.
  defp base_for_input_animation(state, binding, _binding_idx) do
    entity_state = if binding.entity_id, do: Map.get(state.entity_states, binding.entity_id)

    case Rules.match_output(binding, entity_state) do
      {:match, _, _, instructions} -> instructions
      :no_match -> %{}
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

  @doc false
  # Walks every binding in the active layout (regardless of whether it
  # references a particular entity) and runs the same match-transition
  # dispatch logic as the per-entity path. Used on layout switch and
  # initial render so continuous animations install immediately rather
  # than waiting for the first entity-state change.
  def dispatch_animations_for_active_layout(state) do
    case get_active_layout(state) do
      nil -> state
      layout -> Enum.reduce(layout.bindings, state, &dispatch_all_bindings(&1, &2))
    end
  end

  defp dispatch_all_bindings({control_id, control_bindings}, state) do
    control_bindings
    |> Enum.with_index()
    |> Enum.reduce(state, fn {binding, idx}, acc ->
      dispatch_binding(binding, idx, control_id, acc)
    end)
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
    instruction_refs = LayoutEngine.extract_instruction_refs(rule.instructions)
    entity_id in when_refs or entity_id in instruction_refs
  end

  defp dispatch_binding(binding, binding_idx, control_id, state) do
    entity_state = if binding.entity_id, do: Map.get(state.entity_states, binding.entity_id)
    match = Rules.match_output(binding, entity_state)
    key = {control_id, binding_idx}
    prev = Map.get(state.last_match, key, :no_match)

    # Refresh the Ticker's base_instructions for any in-flight
    # animation BEFORE the rule-transition logic runs. Input-rule
    # `:event_one_shot` flights (touch flash, ripple) capture their
    # base at trigger time and would otherwise render against stale
    # state across an HA-driven re-render — visually: the icon stays
    # on the old state until the next state change. Ticker no-ops
    # if no animation is installed for the control.
    case match do
      {:match, _, _, instructions} ->
        Ticker.refresh_base(state.device_id, control_id, instructions)

      :no_match ->
        :ok
    end

    apply_match_transition(state.device_id, control_id, prev, match)
    %{state | last_match: Map.put(state.last_match, key, match_summary(match))}
  end

  # Only track matches against rules that actually have animation
  # hooks. A non-animated rule transitioning to/from any other state
  # has no Ticker work to do, and tracking it would let `cancel_all`
  # fire when leaving a non-animated rule — which would wipe
  # animations installed by *other bindings* on the same control
  # (cross-binding interference). Mapping non-animated matches to
  # `:no_match` keeps them invisible to the dispatch state machine.
  #
  # Animated rules (any of animations / on_enter / transitions /
  # on_change populated) carry the resolved instructions in the
  # third tuple element so the next dispatch can diff them for
  # per-property `transitions` / `on_change` hooks.
  defp match_summary({:match, rule_idx, %OutputRule{} = rule, instructions}) do
    if rule_animated?(rule) do
      {:matched, rule_idx, instructions}
    else
      :no_match
    end
  end

  defp match_summary(:no_match), do: :no_match

  # `rule_has_no_same_idx_work` covers the three hooks that fire on
  # same-rule re-matches (continuous animations, transitions,
  # on_change). `on_enter` is deliberately excluded: it fires only on
  # rule entry, so a rule whose only hook is `on_enter` has nothing
  # to do on same-idx — but its match still needs tracking so the
  # cancel-and-install path can fire it on the next entry. That's why
  # `rule_animated?/1` ORs `on_enter` on top of the same-idx guard.
  defguardp rule_has_no_same_idx_work(rule)
            when rule.animations == [] and
                   map_size(rule.transitions) == 0 and
                   map_size(rule.on_change) == 0

  defp rule_animated?(%OutputRule{} = rule) do
    rule.on_enter != [] or not rule_has_no_same_idx_work(rule)
  end

  defp apply_match_transition(_device_id, _control_id, :no_match, :no_match), do: :ok

  defp apply_match_transition(device_id, control_id, {:matched, _, _}, :no_match) do
    Ticker.cancel_rule_animations(device_id, control_id)
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
         {:matched, prev_idx, _prev_instructions},
         {:match, idx, rule, instructions}
       )
       when prev_idx != idx do
    Ticker.cancel_rule_animations(device_id, control_id)
    install_rule_animations(device_id, control_id, rule, instructions)
  end

  # Same rule, same idx — animation install happened on the prior
  # transition. Skip via the shared `rule_has_no_same_idx_work` guard
  # so the predicate can't drift from `rule_animated?/1`'s definition.
  defp apply_match_transition(
         _device_id,
         _control_id,
         {:matched, _, _},
         {:match, _, rule, _}
       )
       when rule_has_no_same_idx_work(rule),
       do: :ok

  # Same rule, same idx — refresh continuous (the Ticker's stale
  # `base_instructions` get replaced with the new resolved values via
  # the install path's W4 dedup, which keeps `started_at` stable so
  # the continuous loop doesn't restart) and fire per-property
  # transitions / on_change keyframes for any property whose resolved
  # value changed.
  defp apply_match_transition(
         device_id,
         control_id,
         {:matched, _, prev_instructions},
         {:match, _, rule, instructions}
       ) do
    refresh_continuous(device_id, control_id, rule, instructions)
    fire_property_diff_hooks(device_id, control_id, rule, prev_instructions, instructions)
  end

  # No-op fast path — no transitions or on_change paths to walk.
  defp fire_property_diff_hooks(
         _device_id,
         _control_id,
         %OutputRule{transitions: t, on_change: c},
         _prev,
         _curr
       )
       when map_size(t) == 0 and map_size(c) == 0,
       do: :ok

  defp fire_property_diff_hooks(device_id, control_id, rule, prev, curr) do
    paths = MapSet.new(Map.keys(rule.transitions) ++ Map.keys(rule.on_change))
    diffs = diff_paths(prev, curr, paths)
    install_property_transitions(device_id, control_id, rule, curr, diffs)
    install_property_on_change(device_id, control_id, rule, curr, diffs)
  end

  # Returns `[{path, old_val, new_val}, ...]` for declared paths
  # whose value changed. `get_in/2` returns nil for missing keys,
  # which collapses "property absent" and "property is nil" into the
  # same case — that's correct: `nil → nil` is not a change.
  defp diff_paths(prev, curr, paths) do
    Enum.flat_map(paths, fn path ->
      old = get_in(prev, path)
      new = get_in(curr, path)
      if old == new, do: [], else: [{path, old, new}]
    end)
  end

  defp install_property_transitions(device_id, control_id, rule, base, diffs) do
    Enum.each(diffs, fn {path, old, new} ->
      case Map.get(rule.transitions, path) do
        # Path declared transitionable but wasn't in the diff for this
        # entry, or no transition declared for this path.
        nil ->
          :ok

        # CSS semantics: no transition on first paint. on_change still
        # fires — the property *did* change, we just have no value to
        # lerp from.
        _spec when is_nil(old) ->
          :ok

        # val → nil (property disappears) installs a flight, but
        # `Tween.lerp_value(a, nil, _)` falls through to `a`, so the
        # rendered value holds at the old value for the duration. This
        # matches "no useful interpolation target" without a special
        # case — pinned by the `val → nil holds the old value` test.
        spec ->
          install_transition_flight(device_id, control_id, base, path, old, new, spec)
      end
    end)
  end

  defp install_transition_flight(device_id, control_id, base, path, old, new, spec) do
    kf = %Keyframes{
      stops: [{0, nest(path, old)}, {100, nest(path, new)}],
      duration_ms: spec.duration_ms,
      easing: spec.easing,
      iterations: 1,
      direction: :normal,
      target: nil,
      name: nil,
      extras: %{}
    }

    # Drop any in-flight transition for this path before installing
    # the replacement. Without this, a re-fire mid-tween would stack
    # two flights — the new flight's 0%-stop is the prior *resolved*
    # value, not the currently-rendered (mid-lerp) value, so the
    # render snaps. on_change and on_enter one-shots are tagged
    # `property_path: nil` and survive the cancel.
    Ticker.cancel_property_transition(device_id, control_id, path)
    Ticker.start_property_transition(device_id, control_id, kf, base, path)
  end

  defp install_property_on_change(device_id, control_id, rule, base, diffs) do
    Enum.each(diffs, fn {path, _old, _new} ->
      case Map.get(rule.on_change, path) do
        nil -> :ok
        kf -> Ticker.start_animation(device_id, control_id, :one_shot, kf, base)
      end
    end)
  end

  # Build a nested map at the given path with `value` as the leaf.
  # `nest([:fill, :amount], 73)` → `%{fill: %{amount: 73}}`. The
  # synthetic transition keyframe's stops nest the lerped value at
  # this path so `Tween.lerp_keyframe` (via `Map.merge` recursion in
  # `lerp_value`) interpolates only the targeted leaf, leaving
  # sibling properties in `base` untouched on the merged frame.
  defp nest([key], value), do: %{key => value}
  defp nest([key | rest], value), do: %{key => nest(rest, value)}

  defp refresh_continuous(device_id, control_id, %OutputRule{} = rule, instructions) do
    Enum.each(rule.animations, fn kf ->
      Ticker.start_animation(device_id, control_id, :continuous, kf, instructions)
    end)
  end

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
    state = %{state | profile: profile, last_match: %{}}

    # Without this, continuous animations on the new layout's bindings
    # don't start until the next entity-state change touches a
    # referenced entity. Walk every binding against current entity
    # states so the Ticker installs animations immediately.
    dispatch_animations_for_active_layout(state)
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
