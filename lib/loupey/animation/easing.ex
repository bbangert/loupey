defmodule Loupey.Animation.Easing do
  @moduledoc """
  CSS-named easing curves and the `resolve/1` facade.

  `resolve/1` takes an easing name (atom) or an explicit
  `{:cubic_bezier, x1, y1, x2, y2}` tuple and returns a 1-arity function
  `(progress) -> eased_progress`. Resolution is intended to happen once
  at profile-load time; the returned function is what the tick loop
  calls.

  Unknown names raise `ArgumentError` immediately so misconfigured
  profiles fail loud at parse time, not per-tick.
  """

  alias Loupey.Animation.CubicBezier

  @ease {0.25, 0.1, 0.25, 1.0}
  @ease_in {0.42, 0.0, 1.0, 1.0}
  @ease_out {0.0, 0.0, 0.58, 1.0}
  @ease_in_out {0.42, 0.0, 0.58, 1.0}

  @type easing_spec ::
          :linear
          | :ease
          | :ease_in
          | :ease_out
          | :ease_in_out
          | :step_start
          | :step_end
          | {:cubic_bezier, number(), number(), number(), number()}

  @type easing_fn :: (float() -> float())

  @spec resolve(easing_spec()) :: easing_fn()
  def resolve(:linear), do: &linear/1
  def resolve(:ease), do: bezier_fn(@ease)
  def resolve(:ease_in), do: bezier_fn(@ease_in)
  def resolve(:ease_out), do: bezier_fn(@ease_out)
  def resolve(:ease_in_out), do: bezier_fn(@ease_in_out)
  def resolve(:step_start), do: &step_start/1
  def resolve(:step_end), do: &step_end/1

  def resolve({:cubic_bezier, x1, y1, x2, y2})
      when is_number(x1) and is_number(y1) and is_number(x2) and is_number(y2) do
    bezier_fn({x1, y1, x2, y2})
  end

  def resolve(other) do
    raise ArgumentError,
          "unknown easing #{inspect(other)} — expected one of " <>
            ":linear, :ease, :ease_in, :ease_out, :ease_in_out, " <>
            ":step_start, :step_end, or {:cubic_bezier, x1, y1, x2, y2}"
  end

  defp bezier_fn({x1, y1, x2, y2}) do
    fn t -> CubicBezier.call(x1, y1, x2, y2, t * 1.0) end
  end

  defp linear(t), do: t * 1.0

  defp step_start(t) when t <= 0.0, do: 0.0
  defp step_start(_t), do: 1.0

  defp step_end(t) when t >= 1.0, do: 1.0
  defp step_end(_t), do: 0.0
end
