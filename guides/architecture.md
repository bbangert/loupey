# Loupey Architecture

## Supervision Tree

```mermaid
graph TD
    App["Loupey.Supervisor<br/><i>one_for_one</i>"]

    App --> PubSub["Phoenix.PubSub<br/><i>Loupey.PubSub</i>"]
    App --> Repo["Loupey.Repo<br/><i>SQLite</i>"]
    App --> Telemetry["LoupeyWeb.Telemetry"]
    App --> Registry["Registry<br/><i>Loupey.DeviceRegistry</i><br/><i>unique keys</i>"]
    App --> HASup["HA.Supervisor<br/><i>rest_for_one</i>"]
    App --> DynSup["DynamicSupervisor<br/><i>Loupey.DeviceSupervisor</i><br/><i>one_for_one</i>"]
    App --> Orch["Loupey.Orchestrator<br/><i>GenServer</i>"]
    App --> Endpoint["LoupeyWeb.Endpoint<br/><i>Phoenix/Cowboy</i>"]

    HASup --> Events["HA.Events<br/><i>ETS cache, always running</i>"]
    HASup -.->|"started on connect"| Conn["HA.Connection<br/><i>WebSockex</i>"]

    DynSup -.->|"restart: transient"| DS1["DeviceServer<br/><i>per device</i>"]
    DynSup -.->|"restart: permanent"| Eng1["Bindings.Engine<br/><i>per device</i>"]

    style DS1 stroke-dasharray: 5 5
    style Eng1 stroke-dasharray: 5 5
    style Conn stroke-dasharray: 5 5
```

Dashed lines indicate dynamically started children.

## Restart Policies

| Process | Restart | Rationale |
|---------|---------|-----------|
| Orchestrator | `:permanent` (supervised) | Always running. Serializes all device/profile/HA coordination. On crash, restarts and re-subscribes to PubSub. |
| HA.Supervisor | `:permanent` (supervised) | Always running. Events starts immediately; Connection starts on demand via `HA.connect/1`. Strategy: `rest_for_one` — if Events crashes, Connection restarts too. |
| HA.Connection | `:permanent` (dynamic child of HA.Supervisor) | Started when user provides HA config. WebSockex handles reconnection internally. If it crashes, HA.Supervisor restarts it. |
| HA.Events | `:permanent` (static child of HA.Supervisor) | Always running so entity lookups never crash. ETS table is rebuilt on restart; Connection re-fetches states on reconnect. |
| DeviceServer | `:transient` (dynamic child of DeviceSupervisor) | Only restarts on abnormal exit. If the device is unplugged (normal exit), stays dead. Reconnection is handled by the Orchestrator. |
| Bindings.Engine | `:permanent` (dynamic child of DeviceSupervisor) | Always restarts. On restart, loads the active profile from the database (not the stale child spec), re-subscribes to PubSub, and re-renders. |

## Engine Crash Recovery

When the Engine crashes and restarts via the DynamicSupervisor:

1. `init/1` loads the **active profile from the database** — not from the
   original child spec arguments, which may be stale after profile edits
2. Re-subscribes to `"device:{device_id}"` PubSub topic
3. Re-subscribes to `"ha:state:{entity_id}"` for each entity in the profile
4. Fetches current entity states from the Events ETS table
5. Sends `:render_active_layout` to re-render the display

If there's no active profile in the DB (deactivated while engine was running),
the engine enters idle state — it listens for events but renders nothing.
The Orchestrator can push a profile update via `Engine.update_profile/2`.

## HA Connection Lifecycle

The HA.Supervisor starts as a child of the Application supervisor in
"idle" state — only the Events is running. The Connection is started
dynamically when `Loupey.HA.connect(config)` is called:

```
1. App starts → HA.Supervisor starts → Events starts (empty ETS)
2. Orchestrator.init subscribes to "ha:connected"
3. Orchestrator.init calls auto_connect_ha() from saved DB config
4. HA.connect(config) → HA.Supervisor.connect(config)
   → starts Connection as dynamic child
5. Connection authenticates, fetches states, subscribes to events
6. Events receives initial_states → populates ETS
7. Events broadcasts "ha:connected"
8. Orchestrator receives :ha_connected → connects devices + starts engines
```

On disconnect/crash:
- Connection crash → HA.Supervisor restarts it → reconnects to HA
- Events crash → HA.Supervisor restarts both (rest_for_one)
  → Events gets empty ETS → Connection reconnects and re-fetches

## Orchestrator

The Orchestrator is a GenServer that serializes all device/profile
coordination to prevent race conditions. It holds minimal state
(just `ha_ready` flag) — the source of truth is always the database.

**Messages handled:**
- `{:call, :connect_all_devices}` — discover and connect all devices
- `{:call, {:activate_profile, id}}` — deactivate all, activate one, start engines
- `{:call, {:deactivate_profile, id}}` — stop engines, mark inactive
- `{:cast, :reload_active_profile}` — reload from DB, push to engines
- `{:call, :status}` — return device/engine/profile status
- `{:info, :ha_connected}` — HA is ready, trigger device connection

**Startup sequence:**
1. Orchestrator starts, subscribes to `"ha:connected"` PubSub
2. Calls `auto_connect_ha()` which reads saved config from DB
3. When HA connects and sends `:ha_connected`, Orchestrator calls
   `do_connect_all_devices()` which discovers devices and starts engines

This replaces the old `Task.start(fn -> Process.sleep(2000) ... end)` pattern.

## PubSub Topics

All communication between processes goes through `Phoenix.PubSub` on
the `Loupey.PubSub` server.

| Topic | Publisher | Subscribers | Message Format |
|-------|-----------|-------------|----------------|
| `"device:{device_id}"` | DeviceServer | Engine, integration tests | `{:device_event, device_id, event}` where event is `PressEvent`, `RotateEvent`, or `TouchEvent` |
| `"ha:state:{entity_id}"` | Events | Engine | `{:ha_state_changed, entity_id, new_state, old_state}` |
| `"ha:state:all"` | Events | (available for future use) | `{:ha_state_changed, entity_id, new_state, old_state}` |
| `"ha:connected"` | Events | Orchestrator, Dashboard LiveView | `:ha_connected` |

PubSub subscriptions are automatically cleaned up when the subscribing
process dies (Phoenix.PubSub uses process monitors internally).

## Process Communication Flow

### Input Path: Device → HA

```
Physical Device
  │ raw UART bytes
  ▼
DeviceServer
  │ Driver.parse(raw) → [PressEvent | RotateEvent | TouchEvent]
  │ PubSub.broadcast("device:{id}", {:device_event, id, event})
  ▼
Bindings.Engine
  │ handle_info({:device_event, ...})
  │ Rules.match_input(event, binding, entity_state, control)
  │   → {:action, "call_service", params}
  │   → {:action, "switch_layout", %{layout: name}}
  │   → :no_match
  ▼
  ├─ call_service → Loupey.HA.call_service(ServiceCall)
  │                    → HA.Connection WebSocket → Home Assistant
  │
  └─ switch_layout → GenServer.cast(self, {:switch_layout, name})
                        → LayoutEngine.clear_all + switch_layout
                        → send_commands → DeviceServer → Device
```

### Output Path: HA → Device

```
Home Assistant
  │ WebSocket state_changed event
  ▼
HA.Connection (WebSockex)
  │ Messages.parse(json) → {:state_changed, id, new, old}
  │ on_event callback
  ▼
HA.Events
  │ ETS insert
  │ PubSub.broadcast("ha:state:{entity_id}", {:ha_state_changed, ...})
  ▼
Bindings.Engine
  │ handle_info({:ha_state_changed, entity_id, new_state, old_state})
  │ LayoutEngine.render_for_entity(layout, entity_id, new_state, spec)
  │   → Rules.match_output(binding, entity_state)
  │     → {:match, render_instructions}
  │   → Renderer.render_frame(instructions, control)
  │   → [DrawBuffer | SetLED]
  ▼
DeviceServer
  │ Driver.encode(RenderCommand) → binary
  │ write to UART
  ▼
Physical Device (display updates)
```

### Profile Activation Path

```
Web UI (ProfilesLive)
  │ "Activate" button click
  ▼
Orchestrator.activate_profile(profile_id)  (GenServer.call)
  │ 1. Deactivate all profiles (stop engines)
  │ 2. Mark profile active in DB
  │ 3. Load profile → Profiles.to_core_profile()
  │ 4. For each discovered device matching device_type:
  │    a. ensure_connected(device_id)
  │    b. start_or_update_engine(device_id, core_profile)
  ▼
DynamicSupervisor.start_child(Loupey.DeviceSupervisor, engine_spec)
  ▼
Bindings.Engine.init/1
  │ 1. Get DeviceSpec from DeviceServer
  │ 2. Subscribe to device events (PubSub)
  │ 3. Load profile (from arg or DB)
  │ 4. Subscribe to HA state changes for referenced entities
  │ 5. Fetch current entity states from Events
  │ 6. Render active layout → send RenderCommands to DeviceServer
```

### Binding Save Path

```
Web UI (ProfileEditorLive)
  │ Save Binding (visual form or YAML)
  ▼
Profiles.create_binding() or update_binding()
  │ Persists YAML + entity_id to SQLite
  ▼
Orchestrator.reload_active_profile()  (GenServer.cast)
  │ Reloads profile from DB
  │ Profiles.to_core_profile() → core Profile struct
  ▼
Engine.update_profile(device_id, core_profile)
  │ GenServer.cast → handle_cast({:update_profile, profile})
  │ 1. Subscribe to any new entities
  │ 2. LayoutEngine.clear_all(spec) → clear all displays
  │ 3. render_active_layout() → re-render with new bindings
  ▼
DeviceServer → Device (display updates)
```

## API Boundaries

### Layer 1: Data (structs, no behavior)

| Module | Purpose |
|--------|---------|
| `Device.Spec` | What a device has (controls, capabilities) |
| `Device.Control` | Single physical control with capabilities |
| `Device.Display` | Pixel dimensions and format for a display control |
| `Events.PressEvent/RotateEvent/TouchEvent` | Normalized input events |
| `RenderCommands.DrawBuffer/SetLED/SetBrightness` | Normalized output commands |
| `HA.EntityState` | Snapshot of an HA entity's state |
| `HA.ServiceCall` | Request to call an HA service |
| `HA.Config` | HA connection configuration |
| `Bindings.Binding/InputRule/OutputRule` | Binding rules |
| `Bindings.Layout/Profile` | Layout and profile containers |

### Layer 2: Functional Core (pure functions)

| Module | Purpose | Key Functions |
|--------|---------|---------------|
| `Bindings.Expression` | `{{ }}` template evaluation | `eval/2`, `eval_condition/2`, `render/2`, `resolve/2` |
| `Bindings.Rules` | Rule matching | `match_input/4`, `match_output/2` |
| `Bindings.LayoutEngine` | Layout rendering | `switch_layout/4`, `render_layout/3`, `render_for_entity/4`, `clear_all/1` |
| `Bindings.YamlParser` | YAML ↔ struct conversion | `parse_binding/1`, `load_binding/2`, `parse_blueprint/1`, `instantiate_blueprint/2` |
| `Bindings.Blueprints` | Blueprint management | `list/0`, `get/1`, `instantiate/2` |
| `Graphics.Color` | Color parsing and RGB565 conversion | `parse/1`, `rgb_to_rgb565/1`, `rgb_binary_to_rgb565/1` |
| `Graphics.Format` | Vix image → device format | `to_device_format/2`, `to_rgb565/1`, `to_jpeg/1` |
| `Graphics.Renderer` | Compositing pipeline | `render_frame/2`, `render_solid/2` |
| `HA.Messages` | HA WebSocket protocol | `parse/1`, `encode_auth/1`, `encode_subscribe/2`, `encode_service_call/2` |
| `Profiles` | Profile context (DB + conversion) | `to_core_profile/1`, CRUD functions |

### Layer 3: Process Boundaries (GenServers, thin wrappers)

| Module | Type | Registered As | Purpose |
|--------|------|---------------|---------|
| `DeviceServer` | GenServer | `{Loupey.DeviceRegistry, device_id}` | UART I/O, event broadcasting, command encoding |
| `Bindings.Engine` | GenServer | `{Loupey.DeviceRegistry, {:engine, device_id}}` | Binding evaluation, layout management. Loads profile from DB on restart. |
| `HA.Events` | GenServer | `Loupey.HA.Events` | Fans hassock cache events into Loupey PubSub |

### Layer 4: Coordination and Web

| Module | Type | Purpose |
|--------|------|---------|
| `Orchestrator` | GenServer | Serializes device discovery, connection, profile activation, engine lifecycle. Subscribes to `ha:connected` for startup sequencing. |
| `Loupey.HA` | Module (facade) | Public API for HA integration (connect, disconnect, query, subscribe) |
| `Loupey.Devices` | Module (facade) | Public API for device discovery and connection |
| `Loupey.Settings` | Module (context) | Ecto context for HA config persistence |
| `Loupey.Profiles` | Module (context) | Ecto context for profile/layout/binding persistence |

## Driver Architecture

Drivers implement the `Loupey.Driver` behaviour:

```elixir
connect(tty, opts) → {:ok, connection_state}
disconnect(connection_state) → :ok
send_raw(connection_state, data) → :ok
parse(driver_state, raw_binary) → {driver_state, [Event.t()]}
encode(RenderCommand.t()) → {command_byte, payload_binary}
device_spec() → Spec.t()
matches?(device_info) → boolean()
```

The driver is a **pure I/O boundary** — it handles transport (UART, USB HID)
and protocol (WebSocket frames, HID reports) but has no business logic.
All decisions about what to render or what actions to take are made by
the functional core in the binding engine.

Currently implemented: `Driver.Loupedeck` (WebSocket over UART, 256kbaud).

## Touch Move Throttling

The Engine throttles `touch_move` events to prevent flooding HA with
service calls during slider dragging:

- `touch_start`: fires immediately
- `touch_move`: only fires if 400ms have elapsed since last send,
  otherwise stashes the latest params
- `touch_end`: flushes any stashed params (ensures final position is sent)

This is a simple time-check throttle with no timers — each event checks
`System.monotonic_time(:millisecond)` against `last_touch_move_at`.
