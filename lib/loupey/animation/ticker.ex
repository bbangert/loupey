defmodule Loupey.Animation.Ticker do
  @moduledoc """
  Per-device animation tick loop.

  One Ticker GenServer runs per active device. It owns the in-flight
  animation state for every control on that device, drives a 30 fps
  tick loop, and dispatches `DrawBuffer` commands to either the live
  `Loupey.DeviceServer` (production) or an injected test target.

  ## Why a per-device process

  Engine and Ticker mirror each other: one process per device for both,
  registered via `Loupey.DeviceRegistry` under different keys. The
  Engine handles event/state routing; the Ticker handles time. Splitting
  them keeps the tick loop's hot path off the Engine's mailbox (HA
  state-change bursts during a profile reload would otherwise compete
  with frame rendering).

  ## Tick scheduling

  Cadence is monotonic-time-corrected: each tick computes the elapsed
  time since the last tick and schedules the next one to land on the
  target 33 ms grid, clamped to `[1, @tick_ms]`. We do not backfill
  missed frames — under sustained scheduler pressure the Ticker drops
  frames rather than catching up, matching CSS animation semantics.

  ## Test injection

  Pass `:render_target` in opts to redirect rendered commands. Default
  is `:device_server` (live path). For tests, `{:test, pid}` sends
  `{:ticker_render, command}` to the given pid; `fun/1` calls the
  function with each command.
  """

  use GenServer
  require Logger

  alias Loupey.Animation.{Keyframes, Tween}
  alias Loupey.Device.{Control, Spec}
  alias Loupey.Graphics.Renderer
  alias Loupey.RenderCommands.DrawBuffer

  @tick_ms 33

  defmodule InFlight do
    @moduledoc false
    @enforce_keys [:keyframe, :started_at, :kind]
    defstruct [:keyframe, :started_at, :kind]
  end

  defmodule ControlAnims do
    @moduledoc false
    @enforce_keys [:control, :base_instructions]
    defstruct [:control, :base_instructions, continuous: [], one_shots: []]
  end

  defmodule State do
    @moduledoc false
    @type t :: %__MODULE__{
            device_id: term(),
            spec: Loupey.Device.Spec.t(),
            last_tick: integer(),
            render_target: term(),
            animations: map()
          }
    @enforce_keys [:device_id, :spec, :last_tick, :render_target]
    defstruct [:device_id, :spec, :last_tick, :render_target, animations: %{}]
  end

  ## Public API

  @doc """
  Start a Ticker for a device. Required opts: `:device_id`, `:spec`.
  Optional `:render_target` for tests (defaults to `:device_server`).
  """
  def start_link(opts) do
    device_id = Keyword.fetch!(opts, :device_id)
    GenServer.start_link(__MODULE__, opts, name: via_tuple(device_id))
  end

  @doc """
  Install an animation on a control. `kind` is `:continuous` (loops
  while installed) or `:one_shot` / `:event_one_shot` (auto-removes
  on completion). `base` is the resolved instructions to render under
  the animation's per-frame overlay.

  Async fire-and-forget. `cast/2` to a missing/dead Ticker is a
  silent no-op, which is exactly what we want for a non-essential
  subsystem — animation failures must never propagate up into the
  Engine. Tests that need to observe Ticker state immediately after
  this call should use `get_state/1` as a barrier (synchronous reply
  flushes prior casts in mailbox order).
  """
  @spec start_animation(
          term(),
          Control.id(),
          :continuous | :one_shot | :event_one_shot,
          Keyframes.t(),
          map()
        ) :: :ok
  def start_animation(device_id, control_id, kind, %Keyframes{} = kf, base)
      when kind in [:continuous, :one_shot, :event_one_shot] do
    GenServer.cast(via_tuple(device_id), {:start_animation, control_id, kind, kf, base})
  end

  @doc """
  Drop all in-flight animations for a control. Engine calls this on
  rule transitions and layout switches. Async fire-and-forget — see
  `start_animation/5` for the sync/async rationale.
  """
  @spec cancel_all(term(), Control.id()) :: :ok
  def cancel_all(device_id, control_id) do
    GenServer.cast(via_tuple(device_id), {:cancel_all, control_id})
  end

  @doc """
  Inspect current animation state — used by tests and `/phx:audit`-style
  introspection. Not part of the hot path. Synchronous, so it doubles
  as a mailbox barrier for tests that need to observe state changes
  applied by prior `cast/2` messages.
  """
  @spec get_state(term()) :: State.t()
  def get_state(device_id) do
    GenServer.call(via_tuple(device_id), :get_state)
  end

  defp via_tuple(device_id) do
    {:via, Registry, {Loupey.DeviceRegistry, {:ticker, device_id}}}
  end

  ## GenServer callbacks

  @impl true
  def init(opts) do
    device_id = Keyword.fetch!(opts, :device_id)
    spec = Keyword.fetch!(opts, :spec)
    render_target = Keyword.get(opts, :render_target, :device_server)

    # Don't schedule a tick on init — idle devices spend most of
    # their time with no animations installed, so 30 fps wakeups
    # would burn CPU for nothing. Ticks start when the first
    # animation lands; they stop when the last one completes.
    {:ok,
     %State{
       device_id: device_id,
       spec: spec,
       last_tick: System.monotonic_time(:millisecond),
       render_target: render_target,
       animations: %{}
     }}
  end

  @impl true
  def handle_cast({:start_animation, control_id, kind, kf, base}, state) do
    was_idle = map_size(state.animations) == 0
    state = install_animation(state, control_id, kind, kf, base)

    if was_idle and map_size(state.animations) > 0 do
      schedule_tick(@tick_ms)
    end

    {:noreply, state}
  end

  def handle_cast({:cancel_all, control_id}, state) do
    {:noreply, %{state | animations: Map.delete(state.animations, control_id)}}
  end

  @impl true
  def handle_call(:get_state, _from, state), do: {:reply, state, state}

  @impl true
  def handle_info(:tick, state) do
    now = System.monotonic_time(:millisecond)
    state = run_tick(state, now)

    # Only reschedule when there's still work to do. If the last
    # animation just completed/cancelled, the tick loop pauses;
    # the next `start_animation/5` will restart it.
    #
    # Monotonic-time-corrected scheduling: aim for `last_tick +
    # @tick_ms * 2` as the next firing, clamped so we never flood
    # (`>= 1 ms`) and never sleep longer than one tick (`<= @tick_ms`).
    # Drift accumulates over one tick max — explicit no-backfill
    # matches CSS semantics.
    if map_size(state.animations) > 0 do
      elapsed = now - state.last_tick
      next_delay = max(1, min(@tick_ms, @tick_ms * 2 - elapsed))
      schedule_tick(next_delay)
    end

    {:noreply, %{state | last_tick: now}}
  end

  defp schedule_tick(delay), do: Process.send_after(self(), :tick, delay)

  ## Animation lifecycle

  defp install_animation(state, control_id, kind, kf, base) do
    case Spec.find_control(state.spec, control_id) do
      nil ->
        Logger.debug("Ticker: no control #{inspect(control_id)} for #{inspect(state.device_id)}")
        state

      %Control{display: nil} ->
        # Animations only render against display-capable controls. LED-only
        # controls go through the existing direct-render path (Engine).
        state

      %Control{} = control ->
        flight = %InFlight{
          keyframe: kf,
          started_at: System.monotonic_time(:millisecond),
          kind: kind
        }

        existing = Map.get(state.animations, control_id)

        ctl =
          if existing do
            existing
            |> add_flight(flight, kind)
            |> Map.put(:base_instructions, base)
          else
            %ControlAnims{control: control, base_instructions: base}
            |> add_flight(flight, kind)
          end

        %{state | animations: Map.put(state.animations, control_id, ctl)}
    end
  end

  # Dedup continuous animations by keyframe identity. The Engine's
  # dispatcher only re-installs on rule transitions, so it never tries
  # to install the same continuous keyframe twice — but a future caller
  # (or a regressed dispatcher) shouldn't be able to grow this list
  # unboundedly. One-shots are NOT deduped: firing a `flash` twice in
  # quick succession is a legitimate use case.
  defp add_flight(ctl, %InFlight{keyframe: kf} = flight, :continuous) do
    if Enum.any?(ctl.continuous, &(&1.keyframe == kf)) do
      ctl
    else
      %{ctl | continuous: [flight | ctl.continuous]}
    end
  end

  defp add_flight(ctl, flight, kind) when kind in [:one_shot, :event_one_shot] do
    %{ctl | one_shots: [flight | ctl.one_shots]}
  end

  ## Tick processing

  defp run_tick(state, now) do
    {new_animations, commands} =
      Enum.reduce(state.animations, {%{}, []}, fn {control_id, ctl}, {acc_anims, acc_cmds} ->
        {next_ctl, command} = process_control(ctl, now)

        acc_anims =
          case next_ctl do
            :empty -> acc_anims
            updated -> Map.put(acc_anims, control_id, updated)
          end

        {acc_anims, [command | acc_cmds]}
      end)

    Enum.each(commands, &dispatch_render(state, &1))

    if commands != [] do
      refresh_displays(state)
    end

    %{state | animations: new_animations}
  end

  defp process_control(%ControlAnims{} = ctl, now) do
    {continuous, cont_frames} = step_flights(ctl.continuous, now)
    {one_shots, shot_frames} = step_flights(ctl.one_shots, now)

    instructions =
      ctl.base_instructions
      |> deep_merge_frames(cont_frames)
      |> deep_merge_frames(shot_frames)

    pixels = Renderer.render_frame(instructions, ctl.control)
    display = ctl.control.display

    command = %DrawBuffer{
      control_id: ctl.control.id,
      x: 0,
      y: 0,
      width: display.width,
      height: display.height,
      pixels: pixels
    }

    if continuous == [] and one_shots == [] do
      {:empty, command}
    else
      {%{ctl | continuous: continuous, one_shots: one_shots}, command}
    end
  end

  defp step_flights(flights, now) do
    Enum.reduce(flights, {[], []}, fn flight, {kept, frames} ->
      kf = flight.keyframe
      elapsed = now - flight.started_at

      case Tween.iteration_and_progress(elapsed, kf.duration_ms, kf.iterations) do
        :done ->
          # Final frame snaps to the last stop's value so the animation
          # finishes at its declared end state, not at whatever the last
          # tick happened to compute.
          {kept, [stamp_target(Tween.lerp_keyframe(kf.stops, 1.0), kf) | frames]}

        {iter, progress} ->
          eased = kf.easing.(progress)
          directed = Tween.apply_direction(eased, iter, kf.direction)
          {[flight | kept], [stamp_target(Tween.lerp_keyframe(kf.stops, directed), kf) | frames]}
      end
    end)
  end

  # Stamp the keyframe's `:target` onto each frame's `:transform` so
  # the renderer routes transforms to the correct layer. Effects that
  # declare `target: :text` (or any non-default target) need this —
  # otherwise the renderer falls back to its `:icon` default. We only
  # stamp when the frame actually carries a transform; pure-overlay
  # frames (pulse, flash, ripple) don't need a target.
  defp stamp_target(%{transform: %{} = transform} = frame, %Keyframes{target: target})
       when not is_nil(target) do
    %{frame | transform: Map.put_new(transform, :target, target)}
  end

  defp stamp_target(frame, _kf), do: frame

  defp deep_merge_frames(base, frames) do
    Enum.reduce(frames, base, &deep_merge(&2, &1))
  end

  defp deep_merge(a, b) when is_map(a) and is_map(b) do
    Map.merge(a, b, fn _key, va, vb ->
      if is_map(va) and is_map(vb), do: deep_merge(va, vb), else: vb
    end)
  end

  defp deep_merge(_a, b), do: b

  ## Render dispatch

  defp dispatch_render(%State{render_target: :device_server, device_id: id}, cmd) do
    Loupey.DeviceServer.render(id, cmd)
  end

  defp dispatch_render(%State{render_target: {:test, pid}}, cmd) do
    send(pid, {:ticker_render, cmd})
  end

  defp dispatch_render(%State{render_target: fun}, cmd) when is_function(fun, 1) do
    fun.(cmd)
  end

  defp refresh_displays(%State{render_target: :device_server, device_id: id, spec: spec}) do
    spec.controls
    |> Enum.filter(&Control.has_capability?(&1, :display))
    |> Enum.map(& &1.display.display_id)
    |> Enum.uniq()
    |> Enum.each(&Loupey.DeviceServer.refresh(id, &1))
  end

  defp refresh_displays(_state), do: :ok
end
