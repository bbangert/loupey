# Dialyzer warnings we've chosen to ignore, with rationale.
#
# Each entry is `{file_path, short_description}`. Dialyxir matches the
# description prefix; a broader prefix silences more warnings. Keep
# entries narrow — this file is the escape hatch, not the norm.

[
  # `lawik/hid` (the HID NIF we depend on) doesn't export typespecs, so
  # dialyzer can't see the return types of `HID.enumerate/0`, `HID.open/1`,
  # etc. It conservatively assumes those calls never return, which makes
  # each `Real` wrapper here look like a function with "no local return".
  # The wrappers do return — it's purely an analysis gap in the dep.
  # Revisit if/when lawik/hid ships typespecs upstream.
  {"lib/loupey/driver/streamdeck/hid_port/real.ex", :no_return}
]
