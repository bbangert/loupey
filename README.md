# Loupey

A Home Assistant controller for stream-deck-class physical devices,
written in Elixir/Phoenix. Map physical buttons, knobs, and touch keys
to HA entities through a web UI, and let the device show live state.

## Supported devices

| Vendor  | Device                          | Transport       | Status |
|---------|---------------------------------|-----------------|--------|
| Loupedeck | Live (VID `0x2EC2` PID `0x0004`) | UART (CDC / WebSocket) | Supported |
| Elgato  | Stream Deck MK.2 (VID `0x0FD9`; PIDs `0x00B9`, `0x0080`, `0x00A5`, `0x006D`) | USB HID | Supported |

The Stream Deck driver covers Elgato's full "Classic" family — MK.2,
Scissor Keys, 2019, and 15-Key Module — which all share one HID
command set. The original MK.1 (`0x0060`) uses a different protocol
and is **not** supported.

## System prerequisites

### Erlang / Elixir

`mix.exs` constrains Elixir to `~> 1.17`. The project is developed and
tested on Erlang/OTP 28 + Elixir 1.19. Install a compatible toolchain
locally — there's no `.tool-versions` committed at the repo root
(yet), so pick your own `mise` / `asdf` versions within those
constraints.

### HID system libraries (for Stream Deck)

The Stream Deck driver depends on `{:hid, github: "lawik/hid"}`, a
NIF wrapper over `libhidapi`. Install the system libraries and their
headers:

```
# Fedora / RHEL
sudo dnf install hidapi hidapi-devel libusbx libusb1-devel

# Debian / Ubuntu
sudo apt install libhidapi-hidraw0 libhidapi-dev libusb-1.0-0 libusb-1.0-0-dev

# macOS (Homebrew)
brew install hidapi libusb
```

On rpm-ostree systems (Bluefin, Silverblue, Kinoite), `dnf install`
won't modify the base image — use `brew install hidapi libusb` from
Homebrew, or `rpm-ostree install` + reboot.

### Running without the Stream Deck driver

If you're only using a Loupedeck, you can omit the HID libraries.
`Loupey.Devices.hid_matches/0` wraps `HID.enumerate/0` in a rescue —
on the first failure (e.g. missing `libhidapi` / `libusb` at runtime)
it logs a warning and returns an empty list; subsequent failures stay
silent, so you won't see repeated log spam on each status poll. The
Stream Deck driver simply never matches any device.

## Getting started

```
mix deps.get
mix ecto.setup
mix phx.server
```

Open <http://localhost:4000> and log into Home Assistant via the web UI.
When Loupey connects to HA, any supported physical devices plugged in
will be auto-detected and a `DeviceServer` started for each.

## Pairing a device

Devices are discovered automatically on startup — just plug them in.
To verify from IEx:

```elixir
iex> Loupey.Devices.discover()
[
  {Loupey.Driver.Loupedeck, "/dev/ttyACM0"},
  {Loupey.Driver.Streamdeck, "/dev/hidraw10"}
]
```

To bind a device to Home Assistant state:

1. Visit `/profiles` and create a profile for your device type.
2. Open the profile editor and click a control on the device grid.
3. Use the blueprint picker to attach an HA entity binding (toggle a
   light, fire a script, show sensor state, etc.).
4. Click **Set as active** on the profile. Loupey pushes the first
   layout's render commands and begins forwarding device events to HA.

## Developing

```
mix test                 # unit tests (89 default-tagged + 19 hardware-gated)
mix test --only integration  # requires a physical device plugged in
mix credo --strict       # code quality (pre-existing findings, non-blocking)
mix compile --warnings-as-errors
```

The architecture is split into three layers:

- **Drivers** (`lib/loupey/driver/`) — transport + protocol per device
  family. Each owns its own transport (UART, HID) entirely; the
  `DeviceServer` is transport-agnostic.
- **Bindings engine** (`lib/loupey/bindings/`) — rule evaluation, HA
  state subscription, render pipeline via `Vix.Vips`.
- **Web UI** (`lib/loupey_web/`) — Phoenix LiveView profile editor,
  device grid, binding editor.

## License

See [LICENSE](LICENSE).
