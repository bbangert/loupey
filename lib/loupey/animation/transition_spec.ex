defmodule Loupey.Animation.TransitionSpec do
  @moduledoc """
  Per-property transition spec — duration + resolved easing.

  Authored as a YAML map under an output rule's `transitions:` block,
  keyed by property path:

      transitions:
        color: { duration_ms: 300, easing: ease_out }
        fill:
          amount: { duration_ms: 200, easing: ease_out }

  The YAML parser flattens nested authoring into a `%{[atom] =>
  TransitionSpec.t()}` map keyed by the engine's diff path
  representation. The Engine fires a synthetic two-stop keyframe
  through the Ticker on same-rule re-match when the value at the
  path changes.
  """

  alias Loupey.Animation.Easing

  @enforce_keys [:duration_ms, :easing]
  defstruct [:duration_ms, :easing]

  @type t :: %__MODULE__{
          duration_ms: pos_integer(),
          easing: Easing.easing_fn()
        }

  @doc """
  Parse an atom-keyed map into a `%TransitionSpec{}`.

  Raises `ArgumentError` on missing `:duration_ms` or unknown easing —
  fail loud at profile-load time, not per-tick.
  """
  @spec parse(map()) :: t()
  def parse(map) when is_map(map) do
    duration = require_pos_integer!(map, :duration_ms)
    easing_spec = Map.get(map, :easing, :linear)

    %__MODULE__{
      duration_ms: duration,
      easing: Easing.resolve(easing_spec)
    }
  end

  defp require_pos_integer!(map, key) do
    case Map.fetch(map, key) do
      {:ok, n} when is_integer(n) and n > 0 ->
        n

      {:ok, other} ->
        raise ArgumentError,
              "expected positive integer for #{inspect(key)}, got #{inspect(other)}"

      :error ->
        raise ArgumentError, "missing required key #{inspect(key)} in transition spec"
    end
  end
end
