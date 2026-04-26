defmodule Loupey.Animation.Keyframes do
  @moduledoc """
  Parsed, validated keyframe-animation definition.

  A `%Keyframes{}` is the runtime form of a CSS-style animation: ordered
  stops, a duration, an iteration count, a direction, an already-resolved
  easing function, and an optional render target. The Ticker only ever
  consumes structs in this shape — string keyframe names live one layer
  above (in `Profile.keyframes`) and are resolved at parse time.

  ## Two authoring shapes

  Inline keyframes:

      %{
        "duration_ms" => 1500,
        "easing" => "ease_in_out",
        "iterations" => :infinite,
        "direction" => "alternate",
        "keyframes" => %{
          "0" => %{"fill" => %{"amount" => 30}},
          "100" => %{"fill" => %{"amount" => 100}}
        }
      }

  Effect shorthand (resolved into a struct by `Loupey.Animation.Effects`):

      %{"effect" => "ripple", "duration_ms" => 400, "color" => "#FFFFFF80"}

  This module handles the inline form. The effect form is dispatched
  through `Loupey.Animation.Effects.from_map/1`.
  """

  alias Loupey.Animation.{Easing, Effects}

  @type stop_pct :: 0..100
  @type stops :: [{stop_pct(), map()}]

  @type t :: %__MODULE__{
          stops: stops(),
          duration_ms: pos_integer(),
          easing: Easing.easing_fn(),
          iterations: pos_integer() | :infinite,
          direction: :normal | :reverse | :alternate | :alternate_reverse,
          target: atom() | nil,
          name: String.t() | nil,
          extras: map()
        }

  @enforce_keys [:stops, :duration_ms, :easing, :iterations, :direction]
  defstruct [
    :stops,
    :duration_ms,
    :easing,
    :iterations,
    :direction,
    :target,
    :name,
    extras: %{}
  ]

  @valid_directions [:normal, :reverse, :alternate, :alternate_reverse]

  @doc """
  Parse a map (already atom-keyed) into a `%Keyframes{}` struct.

  Raises `ArgumentError` with a descriptive message on missing required
  keys, malformed stop percentages, or unknown easing names. The aim is
  fail-loud at profile-load time, not per-tick.
  """
  @spec parse(map()) :: t()
  def parse(map) when is_map(map) do
    case Map.get(map, :effect) do
      nil -> parse_inline(map)
      effect_name -> Effects.from_map(effect_name, map)
    end
  end

  defp parse_inline(map) do
    duration = require_pos_integer!(map, :duration_ms)
    easing_spec = Map.get(map, :easing, :linear)
    iterations = parse_iterations(Map.get(map, :iterations, 1))
    direction = parse_direction(Map.get(map, :direction, :normal))
    target = Map.get(map, :target)
    raw_stops = require_stops!(map)

    %__MODULE__{
      stops: normalize_stops(raw_stops),
      duration_ms: duration,
      easing: Easing.resolve(easing_spec),
      iterations: iterations,
      direction: direction,
      target: target,
      name: Map.get(map, :name),
      extras: Map.drop(map, ~w(duration_ms easing iterations direction target name keyframes)a)
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
        raise ArgumentError, "missing required key #{inspect(key)} in keyframe definition"
    end
  end

  defp require_stops!(map) do
    case Map.get(map, :keyframes) do
      stops when is_map(stops) and map_size(stops) > 0 ->
        stops

      _ ->
        raise ArgumentError,
              "keyframe definition requires a non-empty :keyframes map " <>
                "(got #{inspect(Map.get(map, :keyframes))})"
    end
  end

  defp parse_iterations(:infinite), do: :infinite
  defp parse_iterations(n) when is_integer(n) and n > 0, do: n

  defp parse_iterations(other) do
    raise ArgumentError,
          "iterations must be a positive integer or :infinite, got #{inspect(other)}"
  end

  defp parse_direction(dir) when dir in @valid_directions, do: dir

  defp parse_direction(other) do
    raise ArgumentError,
          "direction must be one of #{inspect(@valid_directions)}, got #{inspect(other)}"
  end

  defp normalize_stops(stops_map) do
    stops_map
    |> Enum.map(fn {pct, value_map} -> {parse_pct(pct), value_map} end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp parse_pct(pct) when is_integer(pct) and pct >= 0 and pct <= 100, do: pct

  defp parse_pct(pct) when is_binary(pct) do
    case Integer.parse(pct) do
      {n, ""} when n >= 0 and n <= 100 -> n
      _ -> raise ArgumentError, "keyframe stop percentage must be 0..100, got #{inspect(pct)}"
    end
  end

  defp parse_pct(other) do
    raise ArgumentError, "keyframe stop percentage must be 0..100, got #{inspect(other)}"
  end
end
