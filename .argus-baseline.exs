# Reviewed argus findings: each is a validated false positive or deliberate
# design, with its reason. Checked by scripts/argus_baseline.exs (see its
# header for the workflow); prefer fixing a finding over adding it here.
[
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
