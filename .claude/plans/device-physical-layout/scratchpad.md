# Scratchpad — device-physical-layout

Running log of decisions, rejected alternatives, and dead-ends. Read
BEFORE retrying approaches here.

## Decisions

### D1: Separate Layout struct, not `:position` on Control

**Chosen:** Add a new `Loupey.Device.Layout` struct alongside `Spec`; expose via an optional variant callback.

**Rejected alternative A — `:position` field on `Loupey.Device.Control`:**
- Would widen the surface of Control (consumed by drivers, encoders, parsers, `Spec.resolve_touch/3`, and DB-serialized `control_id`s) for purely UI-layout concerns.
- Would duplicate/drift against `Display.offset` which already carries x/y for display-capable controls.

**Rejected alternative B — per-device `<svg>` template file:**
- Higher authoring cost per variant.
- Couples the UI asset to the spec; easy to drift when a variant adds/removes a control.

### D2: Keep existing row-stacked layout as fallback

If a variant doesn't implement `layout/0`, DeviceGrid falls back to the current renderer. This means:
- No regression for unknown/future variants.
- New variants can ship a spec + driver first, layout second.

### D3: Event contract stays identical

`phx-value-control` strings (from `format_control_id/1`) must be byte-identical before and after. ProfileEditorLive's `handle_event("select_control", ...)` and `parse_control_id/1` don't change. Phase 6 adds a regression test for this.

### D4: Face coordinate space is abstract px, scaled with CSS

Each variant picks its own `face_width × face_height` in whatever px scale is natural (likely the device's physical mm × some factor, or reuse Display pixel coords). The component applies `transform: scale(...)` on a wrapper to fit the editor column. This keeps per-variant coords intuitive to author.

### D5: Loupedeck Live face proportions match the official product photo

Initial coords (600×380, 40 px knobs, buttons spanning display width only) made the face look squashed vs. the real device. Reworked against the Loupedeck official photo to get the proportions right:

- **face:** 720 × 600
- **display position:** offset 120 px from the left, 120 px from the top (knob gutters + logo chassis)
- **knobs:** 60 px, centered in 120 px side gutters, vertically aligned to the three key rows
- **buttons:** 54 px (slightly smaller than knobs), first and last centers aligned with the left/right knob columns — pitch 86 px so button row spans knob-column-to-knob-column, not the full face width

If Loupedeck CT / Stream Deck Plus get added later, each needs its own hand-authored face dims + knob/button placements.

### D6: Container queries for responsive device scaling

DeviceGrid uses `container-type: inline-size` on the outer wrapper + `transform: scale(calc(100cqi / face_width))` on the positioned inner div. The face fills its container at any width, preserving `face_width / face_height` aspect ratio. No fixed `scale` prop needed.

Button/knob labels inside the scaled container use `text-base` + `font-medium` in layout-coord units — they scale proportionally with the face.

### D7: Profile editor uses a slide-out drawer, not a side column

Binding editor lives in a fixed-position right-side drawer (2/3 viewport width on md+) that opens when a control is clicked and closes via X button or backdrop click. "Layout Actions" moved above the Layouts selector; Device Layout now spans the full page width.

Drawer implementation detail that matters: **backdrop must stay in the DOM at all times**, opacity toggled via `opacity-0 pointer-events-none` / `opacity-100`. See DE2.

### D8: Binding editor uses a bigger baseline font size than the rest of the app

Drawer contents (blueprint picker, binding form, condition builder, entity autocomplete) use `text-base` / `text-lg` everywhere — one tier larger than the default Phoenix text-sm baseline used on the main page. Rationale: the drawer is the dense interaction surface; labels + inputs at `text-xs` were hard to scan. The device-layout and layouts cards on the main page still use their smaller sizes.

## Dead-ends

### DE1: Planned misc-button positions for 12 phantom controls

Initial plan placed `:home`, `:undo`, `:keyboard`, `:enter`, `:save`, `:fn_l`, `:a`, `:b`, `:c`, `:d`, `:e`, `:fn_r` in a 3×4 grid below the display. **User correction:** these controls don't physically exist on the Loupedeck Live. Likely copied from a Loupedeck CT spec when the variant was first authored.

Also `:knob_ct` (top-center knob) was declared but doesn't exist — the Live has 6 knobs (3L + 3R), not 7.

**Upshot:** Phase 2 now removes them from `Variant.Live`, `loupedeck.ex @button_ids` (`0x00` and `0x0F..0x1A`), and the `:home`-as-example test fixture in `spec_test.exs`. Layout only places the 6 real knobs + 8 real buttons.

### DE2: Drawer open-slide broke when backdrop was `:if={@open}`

First drawer implementation wrapped the backdrop with `:if={@open}`. Closing animated correctly (backdrop removed, drawer slid out). Opening rendered the drawer at its final `translate-x-0` position with **no** transition — because inserting the backdrop sibling between two elements made LiveView treat the drawer as a newly-mounted element, and new DOM inserts skip transitions (no "from" state).

**Fix:** Keep the backdrop permanently in the DOM, toggle `opacity-0 pointer-events-none` vs. `opacity-100`. Both elements now stay in place; only their attribute classes change, so `transform: translateX(...)` transitions fire correctly on both open and close.

### DE3: Dead `Layout.get/1` in first review pass

Plan originally specified `Loupey.Device.Layout.get/1` (takes a variant module, uses `function_exported?/3`). Implementation ended up dispatching via `driver.device_layout/0` (driver-level callback), leaving `Layout.get/1` unused. Parallel review flagged it; removed the function + its tests rather than keep dead public API.

### DE4: Initial scale was fixed at 1.0, then tried 0.65 — both wrong

Iterated three times before landing on container queries:

1. **scale=1.0** → overflowed narrow cards (720 px face > lg:col-span-2 width on medium laptops).
2. **scale=0.65** default → rendered at 468 px on any screen, wasting space on wide monitors.
3. **Container queries** (D6) → scales continuously to fill the parent at any size.

The lesson: don't bake a fixed scale into a component that renders at wildly-varying container widths.

## Open questions

- [ ] Is there a Loupedeck CT variant coming? If so, the dropped misc-button positions + `:knob_ct` could be restored there with a separate variant module. Out of scope for this plan.
