# Plan: Physical-Layout Device View in Profile Editor

## Summary

Render each device's controls in the Profile Editor at their **actual physical positions** (knobs flanking the display, press-only buttons below, touch strips as tall rectangles on the sides), replacing today's approximate row-stacked layout. Scope: profile editor only — no backend/schema changes, UI-only concern.

~250-400 LOC across ~25 tasks, one PR. No new deps. Also cleans up phantom controls (`:knob_ct` + 12 misc buttons) that exist in the Loupedeck Live variant spec + HID decoder but have no physical counterpart on the device.

## Inputs

Feature request only — no prior review/investigation to incorporate.

## Context — current state

The profile editor at [lib/loupey_web/live/profile_editor_live.ex](lib/loupey_web/live/profile_editor_live.ex) renders the device via the [`DeviceGrid.grid/1`](lib/loupey_web/components/device_grid.ex#L14) function component. Today that component:

- Filters `spec.controls` into 4 buckets by id/capabilities (keys, knobs, buttons, strips).
- Stacks them in **three fixed rows**: top (strip‑keys‑strip), middle (all buttons), bottom (all knobs).

This is approximately right for a Loupedeck Live (strips + 4×3 keys + knobs) but:

- **Loupedeck Live** — 6 knobs sit **flanking** the 4×3 key grid (3 left, 3 right), not stacked below. 8 round touch buttons sit below the display.
- **Stream Deck Classic** — just a 5×3 key grid. Current code still renders empty knob/button/strip rows.
- **Future variants** (Stream Deck Plus/XL, Loupedeck CT) will each need their own physical layout.

### Spec + HID decoder phantoms

Independent of the UI issue, the Loupedeck Live variant and HID decoder declare controls that **don't physically exist on the device** — likely copied from a Loupedeck CT spec:

- [lib/loupey/device/variant/live.ex](lib/loupey/device/variant/live.ex) declares 7 knobs (includes `:knob_ct`) and 12 misc buttons (`:home, :undo, :keyboard, :enter, :save, :fn_l, :a, :c, :fn_r, :b, :d, :e`) that aren't on the Live.
- [lib/loupey/driver/loupedeck.ex:38-66](lib/loupey/driver/loupedeck.ex#L38-L66) maps HID button IDs `0x00` and `0x0F..0x1A` to those phantoms.

Bindings on phantom controls would never fire. Cleaning them up here keeps the Layout complete (every declared control has a physical location) and the HID decoder honest.

The underlying [`Loupey.Device.Spec`](lib/loupey/device/spec.ex) + [`Control`](lib/loupey/device/control.ex) already carry `Display.offset + width + height` for controls with the `:display` capability (used for render‑target addressing and touch hit‑testing in `Spec.resolve_touch/3`). But **knobs, press-only buttons, and misc buttons have no positional data** because they don't render pixels — so DeviceGrid has nothing to lay them out with.

## Approach

Add a **UI-only Layout struct** alongside each variant's `device_spec/0`, keeping `Spec`/`Control`/`Display` untouched so drivers, encoders, parsers, and `resolve_touch/3` are unaffected.

```elixir
%Loupey.Device.Layout{
  face_width: 620,       # device face in layout-space px (abstract; scales in CSS)
  face_height: 380,
  positions: %{
    {:key, 0}     => %{x: 60,  y: 0,   width: 90, height: 90, shape: :square},
    :knob_tl      => %{x: 15,  y: 30,  width: 40, height: 40, shape: :round},
    :left_strip   => %{x: 0,   y: 0,   width: 60, height: 270, shape: :rect},
    {:button, 0}  => %{x: 100, y: 290, width: 40, height: 25,  shape: :pill},
    # ...
  }
}
```

The Variant behaviour gains an optional `layout/0` callback. Variants that implement it get physical rendering; ones that don't fall back to the current row-stacked grid (no regression for unknown/future variants).

`DeviceGrid` becomes a thin renderer: one `position: relative` parent sized to `face_{width,height}`, each control is a `position: absolute` `<button>` placed from the Layout map. `@selected` + `has_binding` styling stays identical.

### Why a separate Layout struct, not a `:position` field on `Control`

Considered adding `:position` directly to `Control`, but:

1. `Spec` and `Control` are consumed by drivers, encoders, parsers, `resolve_touch/3`, and DB-serialized `control_id` values. Adding a UI-only field there widens their surface for no runtime benefit.
2. `Display.offset` already carries positional data for the display region (touch hit-testing). Adding `Control.position` would duplicate and risk drift with `display.offset`.
3. A standalone `Layout` cleanly separates "what controls exist + what can they do" (Spec) from "where are they drawn in the editor UI" (Layout).

Decision recorded in scratchpad.md.

## Phases

### Phase 1 — Layout data model

- [ ] Create `lib/loupey/device/layout.ex` with `%Loupey.Device.Layout{face_width, face_height, positions}`. `positions` is `%{Control.id() => %{x, y, width, height, shape}}`. `shape` enum: `:square | :round | :rect | :pill`. Add `@type`, `@enforce_keys`, `defstruct`, `@moduledoc` explaining UI-only scope.
- [ ] Add an **optional** `@callback layout() :: Loupey.Device.Layout.t() | nil` to [lib/loupey/device/variant.ex](lib/loupey/device/variant.ex). Mark optional via `@optional_callbacks layout: 0`.
- [ ] Add `Loupey.Device.Layout.get/1` accepting a variant module; returns the layout or `nil` if the callback isn't implemented (use `function_exported?/3`).
- [ ] Test `test/loupey/device/layout_test.exs`: constructor with typical maps, `get/1` returns nil for modules without the callback, returns the struct for modules with it.

### Phase 2 — Clean up phantom controls in Loupedeck Live spec + driver

These don't physically exist on the Live and would never fire; remove before authoring the Layout so every declared control has a real position.

- [ ] `lib/loupey/device/variant/live.ex` — drop `:knob_ct` from `knob_controls/0` (keep the remaining 6). Remove `misc_button_controls/0` and its call site in `device_spec/0`.
- [ ] `lib/loupey/driver/loupedeck.ex:38-66` — remove the `@button_ids` entries for `0x00` and `0x0F..0x1A`. Keep only the 6 knobs (`0x01..0x06`) and the 8 primary buttons (`0x07..0x0E`). Verify `@control_to_hw` still compiles (it's derived from `@button_ids`).
- [ ] Confirm `parse/2` in the driver gracefully ignores unknown HID button IDs (unmapped `0x00` etc. in event reports). Adjust if a match is too strict.
- [ ] `test/loupey/device/spec_test.exs:46,76` — replace the `:home` fixture example with a non-phantom id (e.g. keep it local to the test, use something like `:example_button` since the test constructs its own ad-hoc spec — not the Live one). Ensures this test is independent of the variant cleanup.
- [ ] Check DB: `Loupey.Schemas.Binding` rows with `control_id` matching any phantom id in any user profile. If the dev DB contains such rows, add a one-off data cleanup note in the PR description (no migration — small-scale personal project, dev-only).
- [ ] `mix test` — all green after cleanup.

### Phase 3 — Populate Loupedeck Live layout

Physical reference (from [lib/loupey/device/variant/live.ex](lib/loupey/device/variant/live.ex) ASCII art + device photos):
- Display: 480 wide × 270 tall (60 left strip, 360 keys, 60 right strip).
- 6 knobs flank the display: `:knob_tl`/`:knob_cl`/`:knob_bl` down the far left; `:knob_tr`/`:knob_cr`/`:knob_br` down the far right.
- 8 round touch buttons (`{:button, 0..7}`) below the display.

- [ ] Implement `layout/0` in `Loupey.Device.Variant.Live`. Pick a sensible face coordinate space (e.g. 600 × 400) and place each control. Reuse the existing `@key_size`, `@display_*` attrs where they apply. Verify the 4×3 key grid positions match the Display.offset values already in `key_controls/0`.
- [ ] Update `test/loupey/device/variant/` tests to assert `layout/0` returns a struct with an entry for every control id in `device_spec().controls` (no control left unplaced).

### Phase 4 — Populate Stream Deck Classic layout

- [ ] Implement `layout/0` in `Loupey.Device.Variant.Classic`. 5 × 3 grid of 72 px keys, no other controls; face dimensions ≈ `5*72 = 360` × `3*72 = 216` plus small border. Positions mirror the Display.offset math already in `key_controls/0`.
- [ ] Update `test/loupey/device/variant/classic_test.exs` for `layout/0` coverage.

### Phase 5 — Rewrite DeviceGrid renderer

- [ ] Add a `layout` attr to `DeviceGrid.grid/1` alongside `spec`. Parent LiveView resolves the variant → layout in `mount/3` and passes it in (see `get_device_spec/1` in [profile_editor_live.ex:502](lib/loupey_web/live/profile_editor_live.ex#L502); add a parallel `get_device_layout/1` returning nil when missing).
- [ ] When `layout` is nil: render the **existing** row-stacked fallback (extract current code into a `defp fallback_grid/1` private component). Prevents regression for variants without a layout.
- [ ] When `layout` is present: render a single `position: relative` container sized to `face_width × face_height` px; for each `{id, %{x, y, width, height, shape}}` emit a `position: absolute` `<button>` with the same `phx-click="select_control"` + selected/has-binding styling used today. Map `shape` → Tailwind classes (`rounded-full` for `:round`, `rounded-xl` for `:pill`, etc.).
- [ ] Keep `short_label/1` labelling so knobs still show `CT`/`TL`/etc.
- [ ] CSS scale: scale the whole container with `transform: scale(...)` from a wrapper div so the editor page can control overall size without touching coordinates. Alternative: percentage-based positions. Pick the simpler one (likely `transform: scale` on a fixed-px container).
- [ ] Tasks above intentionally keep event contract unchanged — `phx-value-control` strings stay identical, so `parse_control_id/1` and the rest of ProfileEditorLive need no changes.

### Phase 6 — Wire into ProfileEditorLive

- [ ] Add `active_layout_geometry` (or similar, disambiguated from the existing `active_layout` binding-group) to the socket assigns in [mount/3](lib/loupey_web/live/profile_editor_live.ex#L20).
- [ ] Pass `layout={@device_layout}` to `<DeviceGrid.grid />` at [profile_editor_live.ex:87](lib/loupey_web/live/profile_editor_live.ex#L87).
- [ ] `reload_profile/3` doesn't need changes (device spec/layout don't change during edit).

### Phase 7 — Component tests

- [ ] Update [test/loupey_web/components/device_grid_test.exs](test/loupey_web/components/device_grid_test.exs) to cover:
  - Rendering with a Layout: one `<button>` per layout entry, styles include the expected `top`/`left` px.
  - Rendering without a Layout: falls back to the current row-stacked output.
  - `phx-value-control` strings are identical under both rendering modes (protects the click contract).

### Phase 8 — Visual verification (manual)

- [ ] Run `mix phx.server`, navigate to `/profiles/:id`, confirm for a Loupedeck Live profile: knobs visibly flank the display, misc buttons are in their physical positions, clicking each opens the correct binding editor.
- [ ] Same for a Stream Deck Classic profile: 5×3 grid renders identical-looking (just in a slightly cleaner container).
- [ ] If no physical device is connected, create a test profile with `device_type` set to each variant manually via the profiles UI.

## Verification

- [ ] `mix compile --warnings-as-errors` clean
- [ ] `mix format --check-formatted` clean
- [ ] `mix credo --strict` — 0 findings (PR #12's exemption stays narrowly on `Evaluator.normalize/1`)
- [ ] `mix test` — all green, including new Layout + DeviceGrid tests
- [ ] `mix dialyzer` — no new warnings (new `@callback` is optional)
- [ ] Manual: profile editor for each of Live + Classic renders correctly

## Risks

- **Coordinate authoring burden per variant** — each new device variant needs hand-authored coordinates for knobs/buttons. Mitigation: the fallback row-stack means unknown variants still work; Layout is additive.
- **CSS scaling at narrow viewports** — a 600 px wide device on a phone screen. Mitigation: the editor is already 3-column on `lg` breakpoint; Layout container can use `transform: scale` bound to CSS `min(1, 100% / face_width * something)` or just overflow-x.
- **`selected_control` compatibility** — the `phx-value-control` strings must stay identical so `parse_control_id/1` keeps working. Phase 4 tasks list this as a guardrail; Phase 6 adds a regression test.
- **Phantom-control cleanup breaks existing dev-DB bindings** — any `Binding` row with a `control_id` referencing `:knob_ct` or a dropped misc id becomes orphaned after Phase 2. Low risk on a personal-project dev DB, but the PR description should call out "delete orphaned bindings manually if present."

## Self-check

- **Is there a simpler approach?** Yes — could hardcode per-device `<svg>` templates. Rejected: higher authoring cost, harder to keep in sync with `device_spec/0`. The Layout map scales better to future variants.
- **Does this work for all current + plausible future devices?** Yes — coordinate-based placement is general. Stream Deck Plus (4×2 keys + 4 knobs + touch strip) and Loupedeck CT (touch wheel) will fit the same model by adding new `:shape` variants if needed (e.g. `:circle_big` for the CT wheel).
- **What's the smallest version that ships value?** Phases 1+2+4 (Live-only) + a minimal ProfileEditorLive change would demo the feature. Classic can follow. I'm keeping both in scope because Classic is trivial once the pipeline exists.

## Out of scope

- Dashboard / live device state mirror (explicitly deferred — user chose profile editor only).
- Settings and Profiles pages — unchanged.
- Device outline / chassis rendering — nice-to-have visual polish; only add if trivial.
- Responsive / mobile editor — current 3-column desktop layout is sufficient for now.
