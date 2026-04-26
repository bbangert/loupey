# Binding Editor Guide

## Overview

The binding editor connects physical device controls (keys, knobs, buttons, strips) to Home Assistant entities. Each binding has:

- **Input rules** — what happens when you interact with the control (press, rotate, touch)
- **Output rules** — how the control's display reacts to HA entity state changes

## YAML Format

Bindings are stored as YAML. You can edit them in the visual editor or switch to the YAML tab for direct editing.

### Basic binding

```yaml
input_rules:
  - on: touch_start
    actions:
      - action: call_service
        domain: light
        service: toggle
        target: "light.living_room"
output_rules:
  - when: 'state_of("light.living_room") == "on"'
    background: "#1a2e1a"
    icon: "icons/neon_blue/Lights_On.png"
    text:
      content: "ON"
      color: "#44FF44"
      font_size: 16
      valign: bottom
  - when: true
    background: "#2e1a1a"
    icon: "icons/neon_blue/Lights_Off.png"
    text:
      content: "OFF"
      color: "#FF4444"
      font_size: 16
      valign: bottom
```

---

## Input Rules

Input rules define what happens when you interact with a control. Rules are evaluated top-down — the first rule whose trigger and condition match fires its actions.

### Triggers

Which triggers are available depends on the control's capabilities:

| Trigger | Description | Controls |
|---------|-------------|----------|
| `touch_start` | Touch contact begins | Display keys, strips |
| `touch_move` | Finger moves on surface | Display keys, strips |
| `touch_end` | Touch contact ends | Display keys, strips |
| `press` | Button/knob pressed down | Knobs, colored buttons, misc buttons |
| `release` | Button/knob released | Knobs, colored buttons, misc buttons |
| `rotate_cw` | Knob rotated clockwise | Knobs |
| `rotate_ccw` | Knob rotated counter-clockwise | Knobs |

### Conditions

Optional `when:` field. If omitted, the rule always matches for its trigger. Uses expression syntax (see [Expressions](#expressions) below).

```yaml
- on: touch_start
  when: 'state_of("light.office") == "on"'
  actions:
    - action: call_service
      domain: light
      service: turn_off
      target: "light.office"
```

### Actions

Each input rule has an `actions:` list. All actions in the list fire when the rule matches.

#### call_service

Calls a Home Assistant service.

| Field | Required | Description |
|-------|----------|-------------|
| `action` | Yes | `"call_service"` |
| `domain` | Yes | Service domain (e.g., `light`, `switch`, `media_player`, `scene`) |
| `service` | Yes | Service name (e.g., `toggle`, `turn_on`, `turn_off`) |
| `target` | Yes | Entity ID to target (e.g., `"light.office"`) |
| `service_data` | No | Map of additional service parameters |

```yaml
actions:
  - action: call_service
    domain: light
    service: turn_on
    target: "light.office"
    service_data:
      brightness: 255
      color_temp: 3000
```

#### switch_layout

Switches the active layout on the device.

| Field | Required | Description |
|-------|----------|-------------|
| `action` | Yes | `"switch_layout"` |
| `layout` | Yes | Name of the layout to switch to |

```yaml
actions:
  - action: switch_layout
    layout: "Media"
```

### Multiple actions

A single rule can fire multiple actions:

```yaml
- on: press
  actions:
    - action: call_service
      domain: light
      service: turn_off
      target: "light.office"
    - action: call_service
      domain: media_player
      service: media_pause
      target: "media_player.tv"
```

### Touch context variables

When a touch event fires, these variables are available in expressions within action parameters:

| Variable | Description |
|----------|-------------|
| `touch_x` | X coordinate in pixels (0 = left edge of control) |
| `touch_y` | Y coordinate in pixels (0 = top edge of control) |
| `touch_id` | Multi-touch identifier |
| `strip_width` / `control_width` | Width of the control's display in pixels |
| `strip_height` / `control_height` | Height of the control's display in pixels |

Example — brightness slider that maps touch position to brightness:

```yaml
- on: touch_start
  actions:
    - action: call_service
      domain: light
      service: turn_on
      target: "light.office"
      service_data:
        brightness: "{{ round((1 - touch_y / strip_height) * 255) }}"
```

---

## Output Rules

Output rules define how a control's display or LED reacts to entity state changes. Rules are evaluated top-down — the first rule whose condition matches produces the render instructions.

### Conditions

The `when:` field determines when the rule matches:

- `when: true` — always matches (use as a fallback/default)
- `when: 'state_of("light.office") == "on"'` — matches when expression is true

### Render properties

| Property | Type | Description |
|----------|------|-------------|
| `background` | `"#RRGGBB"` | Solid background color |
| `icon` | String (path) | Icon image file path |
| `color` | `"#RRGGBB"` | LED color (for button controls with `:led` capability) |
| `fill` | Map | Partial fill bar (see below) |
| `text` | String or Map | Text label (see below) |

#### fill

Renders a partial color fill — useful for sliders, meters, progress bars.

| Field | Type | Description |
|-------|------|-------------|
| `amount` | Number or expression | 0–100, percentage of area to fill |
| `direction` | String | `to_top`, `to_bottom`, `to_left`, `to_right` |
| `color` | `"#RRGGBB"` | Fill color |

```yaml
fill:
  amount: '{{ (attr_of("light.office", "brightness") || 0) / 255 * 100 }}'
  direction: to_top
  color: "#FFD700"
```

#### text

Simple form — just a string:
```yaml
text: "Hello"
```

Advanced form — map with properties:

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `content` | String | (required) | Text to display. Supports `{{ }}` templates. |
| `color` | `"#RRGGBB"` | `"#FFFFFF"` | Text color |
| `font_size` | Integer | `16` | Font size in pixels |
| `align` | String | `center` | Horizontal: `left`, `center`, `right` |
| `valign` | String | `middle` | Vertical: `top`, `middle`, `bottom` |
| `orientation` | String | `horizontal` | `horizontal` or `vertical` |

```yaml
text:
  content: '{{ state_of("sensor.temp") }}°F'
  color: "#44AAFF"
  font_size: 20
  valign: bottom
  orientation: vertical
```

Use `\n` for line breaks in text content.

---

## Animations

Animations layer on top of rules — both input and output. They render through a 30 fps tick loop while in flight and clean up automatically when complete. Authors usually write the `effect:` shorthand; longhand `keyframes:` blocks are available for custom animations.

### Hook reference

| Hook | Where | Fires when | Typical use |
|------|-------|------------|-------------|
| `animation:` | Input rule | On the event (`touch_start`, `press`, …) | Touch flash, press squish |
| `animation:` / `animations:` | Output rule | While the rule is matched (loops) | Breathing glow, pulsing alert |
| `on_enter:` | Output rule | The instant the rule becomes the matched rule | Shake on alert state |
| `transitions:` | Output rule | Same rule still matches but a declared property's resolved value changed | Smooth slider glide, color tween |
| `on_change:` | Output rule | Same condition as `transitions:`, but fires a one-shot keyframe instead of a tween | Ripple overlay on brightness change |

`transitions:` and `on_change:` only fire on **same-rule re-matches**. When the matched rule changes (e.g. `state == "on"` → `state == "off"`), the engine cancels everything via the rule-transition path and re-installs `animation:`/`on_enter:` for the new rule.

### Effect catalog

The `effect:` shorthand picks a built-in animation; override the defaults via the same map.

| Effect | Behavior | Default duration | Default iterations | Effect-specific options |
|--------|----------|-----------------:|-------------------:|-------------------------|
| `pulse` | Translucent overlay opacity oscillation | 1200 ms | `infinite` (alternate) | `color` (default `"#FFFFFF"`), `intensity` (0–255, default 64) |
| `flash` | Bright overlay → fade transparent | 250 ms | 1 | `color`, `intensity` (default 200) |
| `ripple` | Overlay pulse fading to transparent | 400 ms | 1 | `color`, `intensity` (default 128) |
| `shake` | Horizontal icon translate oscillation | 300 ms | 1 | `amplitude` (default 4 px) |
| `wiggle` | Icon rotation oscillation | 400 ms | 1 | `angle` (default 8°) |
| `squish` | Icon scale-down bounce | 200 ms | 1 | `min_scale` (default 0.92) |

All effects also accept the universal options `duration_ms`, `easing`, and `iterations`. `direction` is overridable on `pulse` only (the others hardcode their motion direction).

### Easing curves

| Name | Behavior |
|------|----------|
| `linear` | Constant speed |
| `ease` | Smooth in and out |
| `ease_in` | Slow start, fast end |
| `ease_out` | Fast start, slow end (good for transitions to a settled state) |
| `ease_in_out` | Slow start and end |
| `step_start` | Jumps to the end value immediately |
| `step_end` | Holds the start value until the end |

### Patterns

#### Touch flash on touch_start

```yaml
input_rules:
  - on: touch_start
    action: call_service
    domain: light
    service: toggle
    target: "light.office"
    animation:
      effect: flash
      duration_ms: 200
      color: "#FFFFFF"
      intensity: 200
```

`flash` and `ripple` are single-shot by default. To use `pulse` for touch feedback, override `iterations: 2` (one fade in + one fade out) — its default of `infinite` is for continuous output-rule glows.

#### Pulsing alert while a state is active

```yaml
output_rules:
  - when: state == "unlocked"
    background: "#FF1B1B"
    text: { content: "UNLOCKED", color: "#FFFFFF", valign: middle }
    animation:
      effect: pulse
      color: "#FFFFFF"
      intensity: 80
      duration_ms: 1000
  - when: state == "locked"
    background: "#0AF019"
    text: { content: "LOCKED", color: "#111111", valign: middle }
```

The locked rule has no `animation:`, so the engine cleanly cancels the pulse when the lock engages and reinstalls it on unlock.

#### Smooth slider glide on brightness change

`transitions:` tweens a property when the rule re-resolves with a different value at that path. Authors write nested YAML; the engine flattens internally to a property-path map.

```yaml
output_rules:
  - when: state == "on"
    background: "#0a0a0a"
    fill:
      amount: '{{ (attributes["brightness"] || 0) / 255 * 100 }}'
      direction: to_top
      color: "#FFD700"
    transitions:
      fill:
        amount:
          duration_ms: 200
          easing: ease_out
```

Tuning: 100–150 ms for "responsive", 200–300 ms for "smooth", 400+ ms feels laggy on actively-dragged sliders.

#### Ripple on a property change

`on_change:` fires a one-shot keyframe when a specific property changes — useful for visual confirmation independent of the property's own rendering.

```yaml
output_rules:
  - when: state == "on"
    background: "#000000"
    fill:
      amount: '{{ (attributes["brightness"] || 0) / 255 * 100 }}'
      direction: to_top
      color: "#FFD700"
    on_change:
      fill:
        amount:
          effect: ripple
          duration_ms: 400
          color: "#FFFFFF"
```

`transitions:` and `on_change:` can target the same property — the tween glides the value while the ripple overlays.

#### Shake on entering a triggered state

`on_enter:` is a list of one-shots fired when the rule first becomes the matched rule.

```yaml
output_rules:
  - when: state == "triggered"
    background: "#330000"
    icon: "icons/neon_blue/Alerts.png"
    on_enter:
      - effect: shake
        duration_ms: 350
        amplitude: 5
  - when: true
    background: "#000000"
    icon: "icons/neon_blue/Alerts_Quiet.png"
```

### Inline keyframes (longhand)

When a built-in effect doesn't fit, write a custom keyframe block. The longhand form takes a `keyframes:` map keyed by stop percentages (0–100):

```yaml
animation:
  duration_ms: 1500
  easing: ease_in_out
  iterations: infinite
  direction: alternate
  keyframes:
    0:
      overlay: "#FFFFFF00"
    50:
      overlay: "#FFFFFF40"
    100:
      overlay: "#FFFFFF00"
```

Stops can target the same instruction shape as the rule itself — `overlay`, `fill`, `transform`, etc. The renderer interpolates numbers and hex colors automatically.

To animate icon translation, rotation, or scale, use `transform:` in keyframe stops with `target: icon` (or `target: text`):

```yaml
on_enter:
  - duration_ms: 400
    target: icon
    keyframes:
      0:
        transform: { rotate: -10 }
      100:
        transform: { rotate: 0 }
```

### Authoring gotchas

- **Quote your colors.** YAML treats `#` as a comment marker. `color: #ffffff` parses as `color: nil` and rejects at save time. Always write `color: "#ffffff"`.
- **`pulse` defaults to `infinite` iterations.** Override `iterations:` (e.g. `2`) when using it as a touch one-shot, or use `flash`/`ripple` instead.
- **`transitions:` skips on first paint.** A property appearing for the first time (`nil → val`) renders the new value instantly; subsequent changes tween. This matches CSS semantics.
- **String-valued properties don't tween.** Text content like `"50%"` → `"55%"` updates instantly; the tween primitive can't interpolate strings. Numbers and hex colors do tween.
- **`transitions:` doesn't fire on rule changes.** Only same-rule re-matches with a changed value at a declared path. Cross-rule changes go through the cancel-and-install path, which fires `on_enter:` (not `transitions:`).
- **Leaf detection in `transitions:` / `on_change:`.** `:duration_ms` (and `:effect` for `on_change`) marks a leaf spec. Mixing a leaf marker with sibling sub-paths at the same level raises a parse-time error so the ambiguity surfaces immediately:

  ```yaml
  # Wrong — :duration_ms makes [:fill] a leaf, but :amount looks like a sub-path
  transitions:
    fill:
      duration_ms: 200
      amount: { duration_ms: 100 }

  # Right — pick one nesting level
  transitions:
    fill:
      amount:
        duration_ms: 200
        easing: ease_out
  ```

---

## Expressions

Expressions are Elixir code snippets used in `when:` conditions and `{{ }}` templates.

### Functions

| Function | Returns | Description |
|----------|---------|-------------|
| `state_of("entity_id")` | String or nil | Get any entity's current state |
| `attr_of("entity_id", "key")` | Any or nil | Get any entity's attribute value |

### Legacy variables

If the binding has an `entity_id` set (deprecated), these variables are also available:

| Variable | Description |
|----------|-------------|
| `state` | The binding entity's state string |
| `attributes` | The binding entity's attributes map (string keys) |
| `entity_id` | The binding entity's ID string |

### Examples

```yaml
# Condition: light is on
when: 'state_of("light.office") == "on"'

# Condition: brightness above 50%
when: 'attr_of("light.office", "brightness") > 128'

# Condition: media player is playing
when: 'state_of("media_player.tv") == "playing"'

# Template: show temperature
text: '{{ state_of("sensor.temperature") }}°F'

# Template: show brightness percentage
text: '{{ round(attr_of("light.office", "brightness") / 255 * 100) }}%'

# Template: show multiple values
text: '{{ state_of("sensor.temp") }}°F\n{{ state_of("sensor.humidity") }}%'

# Arithmetic in fill amount
fill:
  amount: '{{ (attr_of("light.office", "brightness") || 0) / 255 * 100 }}'
```

### Supported Elixir operators

Expressions support standard Elixir operators:

- Comparison: `==`, `!=`, `>`, `<`, `>=`, `<=`
- Logical: `and`, `or`, `not`
- Arithmetic: `+`, `-`, `*`, `/`
- Functions: `round()`, `trunc()`, `abs()`, `min()`, `max()`
- String: `<>` (concatenation)
- Nil coalescing: `||` (e.g., `attr_of("x", "y") || 0`)

---

## Loupedeck Live Controls

### Physical layout

```
┌──────┬──────────────────────────┬──────┐
│ Left │         Center           │Right │
│strip │    4×3 grid of keys      │strip │
│60×270│  K0  K1  K2  K3          │60×270│
│      │  K4  K5  K6  K7          │      │
│      │  K8  K9  K10 K11         │      │
└──────┴──────────────────────────┴──────┘
     [B0] [B1] [B2] [B3] [B4] [B5] [B6] [B7]
  (TL)(TR)  (CT)  (CL)(CR)  (BL)(BR)  ← knobs
```

### Control capabilities

| Control | ID | Capabilities | Display |
|---------|----|----|---------|
| Touch keys | `{:key, 0}` – `{:key, 11}` | touch, display | 90×90 px |
| Left strip | `:left_strip` | touch, display | 60×270 px |
| Right strip | `:right_strip` | touch, display | 60×270 px |
| Colored buttons | `{:button, 0}` – `{:button, 7}` | press, led | — |
| Knobs | `:knob_tl`, `:knob_tr`, etc. | rotate, press | — |
| Misc buttons | `:home`, `:undo`, etc. | press | — |

### Which triggers work on which controls

| Control type | Available triggers |
|-------------|-------------------|
| Touch keys / strips | `touch_start`, `touch_move`, `touch_end` |
| Colored buttons | `press`, `release` |
| Knobs | `press`, `release`, `rotate_cw`, `rotate_ccw` |
| Misc buttons | `press`, `release` |

---

## Blueprints

Blueprints are pre-built binding templates. Select one from the dropdown in the binding editor, fill in the inputs, and click "Apply" to generate a complete binding.

### Available blueprints

| Blueprint | Description | Inputs |
|-----------|-------------|--------|
| Light Toggle | Display key with on/off icons, touch to toggle | entity, icons, colors |
| Switch Toggle | Display key for switches | entity, colors |
| Brightness Slider | Vertical strip with fill bar | entity, fill color |
| Brightness Knob | Rotate for brightness, press to toggle | entity, step size |
| Media Play/Pause | Display key with play/pause icons | entity |
| Volume Knob | Rotate for volume, press to play/pause | entity |
| Layout Switch | Key/button that switches layouts | layout name, label, color |
| Sensor Display | Shows a sensor value | entity, unit suffix, color |

### Custom blueprints

Add YAML files to `priv/blueprints/` with this format:

```yaml
name: "My Blueprint"
description: "What it does"
inputs:
  entity:
    type: entity
    domain: light
    description: "The light to control"
  my_color:
    type: color
    default: "#FFD700"
    description: "Accent color"
input_rules:
  - on: touch_start
    action: call_service
    domain: light
    service: toggle
    target: "{{ inputs.entity }}"
output_rules:
  - when: true
    background: "{{ inputs.my_color }}"
```

### Blueprint input types

| Type | UI Widget | Description |
|------|-----------|-------------|
| `entity` | Autocomplete | HA entity picker, filtered by `domain` |
| `color` | Color picker | Hex color `#RRGGBB` |
| `icon` | Text input | Icon file path |
| `string` | Text input | Free text |
| `number` | Number input | Numeric value |

---

## Visual Editor vs YAML

The binding editor has two tabs:

- **Visual** — Form-based editor with dropdowns, color pickers, and the condition builder. Good for common configurations.
- **YAML** — Direct YAML text editing. Supports the full binding syntax. Use for advanced configurations or expressions not supported by the visual builder.

Changes in either tab are independent until saved. The visual editor generates YAML on save; the YAML tab saves directly.

### Condition Builder

The visual editor includes a structured condition builder for output rules:

1. **Pick an entity** from the autocomplete dropdown
2. **Select property** — `state` or `attribute` (with attribute name)
3. **Select operator** — equals, not equals, greater than, less than
4. **Enter comparison value**
5. **Click "Set condition"** — generates the expression automatically

Toggle to "Raw" mode for direct expression editing.

### Insert Entity Value

Below the text content field, an "Insert entity value" helper:

1. **Pick an entity** from autocomplete
2. **Click "Insert"** — appends `{{ state_of("entity_id") }}` to the text field

Use this to build multi-entity text displays without memorizing entity IDs.
