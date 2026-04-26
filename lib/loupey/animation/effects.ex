defmodule Loupey.Animation.Effects do
  @moduledoc """
  Built-in parameterized animation effects.

  Each effect builds and returns a `%Keyframes{}` struct ready for
  the Ticker to consume. Authors reference an effect by name in
  YAML — `effect: pulse` — and override defaults via the same map:

      animation:
        effect: pulse
        duration_ms: 1500
        color: "#FFD700"

  The dispatch entrypoint is `from_map/2`, called by
  `Keyframes.parse/1` whenever it sees an `:effect` key.

  All effects bottom out in `Keyframes.parse/1`, so error semantics
  (raise on unknown easing, malformed stops) are uniform with the
  inline-keyframe path.
  """

  alias Loupey.Animation.Keyframes

  @type t :: Keyframes.t()
  @type opts :: map()

  @doc """
  Build a keyframe struct from an `effect:` shorthand map. Unknown
  effect names raise — fail loud at profile-load time.
  """
  @spec from_map(atom() | String.t(), opts()) :: t()
  def from_map(effect, opts) when is_binary(effect) do
    case safe_existing_atom(effect) do
      {:ok, atom} -> from_map(atom, opts)
      :error -> raise ArgumentError, "unknown effect #{inspect(effect)}"
    end
  end

  def from_map(:pulse, opts), do: pulse(opts)
  def from_map(:flash, opts), do: flash(opts)
  def from_map(:shake, opts), do: shake(opts)
  def from_map(:wiggle, opts), do: wiggle(opts)
  def from_map(:squish, opts), do: squish(opts)
  def from_map(:ripple, opts), do: ripple(opts)

  def from_map(other, _opts) do
    raise ArgumentError, "unknown effect #{inspect(other)}"
  end

  # Wrap `String.to_existing_atom/1` in a tagged tuple so the rescue
  # block doesn't re-raise (which would trip credo's reraise check) —
  # we want to surface a custom "unknown effect" message, not the
  # generic `ArgumentError` from atom resolution.
  defp safe_existing_atom(str) do
    {:ok, String.to_existing_atom(str)}
  rescue
    ArgumentError -> :error
  end

  @doc """
  `pulse` — overlay opacity oscillation. Sits on top of the base
  render as a translucent wash that fades in and out.
  """
  @spec pulse(opts()) :: t()
  def pulse(opts) do
    color = Map.get(opts, :color, "#FFFFFF")
    intensity = Map.get(opts, :intensity, 64)
    transparent = with_alpha(color, 0)
    opaque = with_alpha(color, intensity)

    Keyframes.parse(%{
      duration_ms: Map.get(opts, :duration_ms, 1200),
      easing: Map.get(opts, :easing, :ease_in_out),
      iterations: Map.get(opts, :iterations, :infinite),
      direction: Map.get(opts, :direction, :alternate),
      keyframes: %{
        0 => %{overlay: transparent},
        100 => %{overlay: opaque}
      }
    })
  end

  @doc """
  `flash` — brief overlay flash that fades to transparent.
  Single-shot by default.
  """
  @spec flash(opts()) :: t()
  def flash(opts) do
    color = Map.get(opts, :color, "#FFFFFF")
    intensity = Map.get(opts, :intensity, 200)
    bright = with_alpha(color, intensity)
    transparent = with_alpha(color, 0)

    Keyframes.parse(%{
      duration_ms: Map.get(opts, :duration_ms, 250),
      easing: Map.get(opts, :easing, :ease_out),
      iterations: Map.get(opts, :iterations, 1),
      direction: :normal,
      keyframes: %{
        0 => %{overlay: bright},
        100 => %{overlay: transparent}
      }
    })
  end

  @doc """
  `shake` — horizontal translate oscillation on the icon target.
  """
  @spec shake(opts()) :: t()
  def shake(opts) do
    amplitude = Map.get(opts, :amplitude, 4)

    Keyframes.parse(%{
      duration_ms: Map.get(opts, :duration_ms, 300),
      easing: Map.get(opts, :easing, :linear),
      iterations: Map.get(opts, :iterations, 1),
      direction: :normal,
      target: :icon,
      keyframes: %{
        0 => %{transform: %{translate_x: 0}},
        25 => %{transform: %{translate_x: -amplitude}},
        50 => %{transform: %{translate_x: amplitude}},
        75 => %{transform: %{translate_x: -amplitude}},
        100 => %{transform: %{translate_x: 0}}
      }
    })
  end

  @doc """
  `wiggle` — small rotational oscillation on the icon.
  """
  @spec wiggle(opts()) :: t()
  def wiggle(opts) do
    angle = Map.get(opts, :angle, 8)

    Keyframes.parse(%{
      duration_ms: Map.get(opts, :duration_ms, 400),
      easing: Map.get(opts, :easing, :ease_in_out),
      iterations: Map.get(opts, :iterations, 1),
      direction: :normal,
      target: :icon,
      keyframes: %{
        0 => %{transform: %{rotate: 0}},
        25 => %{transform: %{rotate: -angle}},
        75 => %{transform: %{rotate: angle}},
        100 => %{transform: %{rotate: 0}}
      }
    })
  end

  @doc """
  `squish` — scale the icon down briefly and bounce back, like a
  press feedback.
  """
  @spec squish(opts()) :: t()
  def squish(opts) do
    min_scale = Map.get(opts, :min_scale, 0.92)

    Keyframes.parse(%{
      duration_ms: Map.get(opts, :duration_ms, 200),
      easing: Map.get(opts, :easing, :ease_in_out),
      iterations: Map.get(opts, :iterations, 1),
      direction: :normal,
      target: :icon,
      keyframes: %{
        0 => %{transform: %{scale: 1.0}},
        50 => %{transform: %{scale: min_scale}},
        100 => %{transform: %{scale: 1.0}}
      }
    })
  end

  @doc """
  `ripple` — overlay pulse that fades to transparent. Accepts a
  change context (`%{old_value:, new_value:}`) but currently doesn't
  use it for positioning; full positional ripple is a v2 enhancement.
  """
  @spec ripple(opts()) :: t()
  def ripple(opts) do
    color = Map.get(opts, :color, "#FFFFFF")
    intensity = Map.get(opts, :intensity, 128)
    bright = with_alpha(color, intensity)
    transparent = with_alpha(color, 0)

    Keyframes.parse(%{
      duration_ms: Map.get(opts, :duration_ms, 400),
      easing: Map.get(opts, :easing, :ease_out),
      iterations: Map.get(opts, :iterations, 1),
      direction: :normal,
      keyframes: %{
        0 => %{overlay: bright},
        100 => %{overlay: transparent}
      }
    })
  end

  # Append `aa` alpha bytes to a `#RRGGBB` string. If the input already
  # carries alpha, replace it. Used to build per-effect overlay colors
  # whose intensity is a numeric option rather than a hex literal.
  defp with_alpha(color, alpha) when is_integer(alpha) and alpha >= 0 and alpha <= 255 do
    base =
      case color do
        "#" <> hex when byte_size(hex) == 6 -> color
        "#" <> hex when byte_size(hex) == 8 -> "#" <> binary_part(hex, 0, 6)
      end

    alpha_hex = alpha |> Integer.to_string(16) |> String.pad_leading(2, "0")
    base <> alpha_hex
  end
end
