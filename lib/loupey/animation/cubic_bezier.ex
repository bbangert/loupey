defmodule Loupey.Animation.CubicBezier do
  @moduledoc """
  Newton-Raphson cubic-bezier solver for CSS-style easing curves.

  Given control points `(x1, y1)` and `(x2, y2)` (with implicit endpoints
  `(0, 0)` and `(1, 1)`), `call/5` returns the interpolated `y` for a
  given `x` in `[0, 1]`. This matches the CSS `cubic-bezier()` timing
  function semantics.
  """

  @epsilon 1.0e-6
  @iterations 8

  @doc """
  Solve a cubic-bezier curve for `t` (a normalized progress in `[0, 1]`).

  Boundary cases short-circuit: `t == 0.0` returns `0.0`, `t == 1.0`
  returns `1.0`. The solver runs Newton-Raphson up to 8 iterations or
  until convergence within `1.0e-6`.
  """
  @spec call(number(), number(), number(), number(), float()) :: float()
  def call(_x1, _y1, _x2, _y2, t) when t <= 0.0, do: 0.0
  def call(_x1, _y1, _x2, _y2, t) when t >= 1.0, do: 1.0

  def call(x1, y1, x2, y2, t) do
    parametric_t = solve_parametric_t(t, x1, x2)
    bezier(parametric_t, y1, y2)
  end

  defp solve_parametric_t(target_x, x1, x2) do
    Enum.reduce_while(1..@iterations, target_x, fn _, guess ->
      current_x = bezier(guess, x1, x2) - target_x

      if abs(current_x) < @epsilon do
        {:halt, guess}
      else
        slope = bezier_slope(guess, x1, x2)

        if abs(slope) < @epsilon do
          {:halt, guess}
        else
          {:cont, guess - current_x / slope}
        end
      end
    end)
  end

  defp bezier(t, p1, p2) do
    a = 1.0 - 3.0 * p2 + 3.0 * p1
    b = 3.0 * p2 - 6.0 * p1
    c = 3.0 * p1
    ((a * t + b) * t + c) * t
  end

  defp bezier_slope(t, p1, p2) do
    a = 1.0 - 3.0 * p2 + 3.0 * p1
    b = 3.0 * p2 - 6.0 * p1
    c = 3.0 * p1
    3.0 * a * t * t + 2.0 * b * t + c
  end
end
