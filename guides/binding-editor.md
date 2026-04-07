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
