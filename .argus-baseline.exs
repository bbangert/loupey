# Reviewed argus findings: each is a validated false positive or deliberate
# design, with its reason. Checked by scripts/argus_baseline.exs (see its
# header for the workflow); prefer fixing a finding over adding it here.
[
  %{
    analysis: "shutdown",
    file: "lib/loupey/ha.ex",
    title: "Children started under another tree outlive their owner",
    at_label: "start_child onto a supervisor in another tree",
    detail:
      "Loupey.HA.call_service/1 starts children under Loupey.HA.TaskSupervisor, a DynamicSupervisor Loupey.Bindings.Engine does not sit under. Their lifetime follows Loupey.HA.TaskSupervisor's tree, not Loupey.Bindings.Engine's: when Loupey.Bindings.Engine's tree shuts down they keep running — reconnecting, logging, calling into applications that have already stopped — and Loupey.Bindings.Engine's terminate/2 does not stop them.",
    reason:
      "Deliberate design: HA service calls are fire-and-forget one-shot requests (a button press turning on a light) that should finish even when the engine that issued them is deactivated or switches profile; tying them to the Engine would drop the user's action on a profile change. They are short Hassock calls bounded by its default request timeout, run under the app-level Loupey.HA.TaskSupervisor, and are :temporary, so a call racing application shutdown just fails inside its own task."
  },
  %{
    analysis: "coupling",
    file: "lib/loupey/orchestrator.ex",
    title: "rest_for_one restarts the owner but not the processes it started",
    at_label: "processes started here outlive their owner's restart",
    detail:
      "Loupey.Orchestrator (position 9) starts processes under DynamicSupervisor (position 7) of Loupey.Application, a rest_for_one supervisor. When Loupey.Orchestrator crashes, the supervisor restarts it and every later child, but DynamicSupervisor started earlier and survives — with the processes the old Loupey.Orchestrator started still running inside it. The new Loupey.Orchestrator knows nothing of them and starts its own: duplicated work, or a stale process holding a resource the replacement expects to own.",
    reason:
      "Deliberate design: the Orchestrator keeps no child pids (its state is only `ha_ready`); every DeviceServer, Engine and Ticker it starts is registered under a unique Loupey.DeviceRegistry key. After a restart it reconciles by registry lookup (ensure_connected/1, engine_running?/1) and start_child treats {:already_started, _} as success (Engine.update_profile/2, Animation.start_ticker/1), so the survivors are adopted rather than duplicated and no resource is double-owned."
  },
  %{
    analysis: "startup",
    file: "lib/loupey/bindings/engine.ex",
    title: "init/1 blocks on a synchronous call",
    at_label: "this init blocks the start sequence",
    detail:
      "Loupey.Bindings.Engine.init/1 makes a synchronous call to Loupey.DeviceServer (directly or transitively) on every init. init runs inside the supervisor's start sequence, so the tree's startup stalls for as long as Loupey.DeviceServer takes to answer. Argus could not establish where Loupey.DeviceServer runs relative to this init — its child spec is built at runtime — so this is a note, not a diagnosis; a proven startup deadlock is reported separately as an error.",
    reason:
      "Deliberate design: Engine is never a static child; the Orchestrator starts it at runtime via DynamicSupervisor.start_child only after safe_get_spec/1 has seen that device's DeviceServer answer. The get_spec call is a cheap state read with a 5s bound, and the device spec is the Engine's precondition: fetching it in init makes start_child return {:error, _} when the device has gone, instead of starting an engine that would crash-loop under its :transient restart and take the DeviceSupervisor down. The expensive work (DB load, HA fetches, first render) is already deferred out of init."
  }
]
