defmodule LoupeyWeb.DeviceGrid do
  @moduledoc """
  Function component that renders a visual representation of a device's
  physical layout, with clickable controls that indicate binding status.

  When a `Loupey.Device.Layout` is provided, each control is absolutely
  positioned at its physical location on the device face. When no layout
  is given (legacy variants without a `layout/0` callback), the component
  falls back to a row-stacked grid — keys + strips on top, misc buttons
  below, knobs at the bottom — which was the original rendering.
  """
  use Phoenix.Component

  @doc """
  Renders the device grid.

  Required attrs:
  - `spec` — `Loupey.Device.Spec` for control metadata.
  - `bindings` — map of `control_id_string => binding`.

  Optional attrs:
  - `layout` — `Loupey.Device.Layout` for absolute positioning.
    Falls back to the row-stacked renderer when `nil`.
  - `selected` — currently selected `control_id` or `nil`.

  When a layout is given, the face scales fluidly via CSS container
  queries to fill its parent's inline size at any width.
  """
  attr :spec, :map, required: true
  attr :bindings, :map, required: true
  attr :layout, :any, default: nil
  attr :selected, :any, default: nil

  def grid(%{layout: nil} = assigns), do: fallback_grid(assigns)

  def grid(assigns) do
    ~H"""
    <div style={"width: 100%; aspect-ratio: #{@layout.face_width} / #{@layout.face_height}; container-type: inline-size"}>
      <div style={"width: #{@layout.face_width}px; height: #{@layout.face_height}px; position: relative; transform-origin: top left; transform: scale(calc(100cqi / #{@layout.face_width}))"}>
        <.positioned_cell
          :for={control <- @spec.controls}
          :if={Map.has_key?(@layout.positions, control.id)}
          control={control}
          position={@layout.positions[control.id]}
          bindings={@bindings}
          selected={@selected}
        />
      </div>
    </div>
    """
  end

  attr :control, :map, required: true
  attr :position, :map, required: true
  attr :bindings, :map, required: true
  attr :selected, :any, default: nil

  defp positioned_cell(assigns) do
    ~H"""
    <button
      phx-click="select_control"
      phx-value-control={format_control_id(@control.id)}
      style={"position: absolute; left: #{@position.x}px; top: #{@position.y}px; width: #{@position.width}px; height: #{@position.height}px"}
      class={[
        "border text-center font-medium text-base leading-tight flex items-center justify-center transition cursor-pointer",
        shape_class(@position.shape),
        status_class(@control.id, @bindings, @selected)
      ]}
    >
      {short_label(@control.id)}
    </button>
    """
  end

  # -- Fallback renderer (used when no Layout is provided) --

  defp fallback_grid(assigns) do
    controls = assigns.spec.controls

    keys = controls |> Enum.filter(&key_control?/1) |> Enum.sort_by(&elem(&1.id, 1))
    knobs = Enum.filter(controls, &knob_control?/1)
    buttons = controls |> Enum.filter(&button_control?/1) |> Enum.sort_by(&elem(&1.id, 1))
    strips = Enum.filter(controls, &strip_control?/1)

    key_px = if keys != [], do: hd(keys).display.width, else: 90
    # Assumes a 3-row key grid (the shape of every current variant). A future
    # 2-row or 4-row device without a Layout would need this heuristic updated,
    # but the intent is that such variants ship with a Layout and skip this
    # fallback entirely.
    cols = length(keys) |> div(3) |> max(1)

    assigns =
      assigns
      |> assign(:keys, keys)
      |> assign(:knobs, knobs)
      |> assign(:buttons, buttons)
      |> assign(:strips, strips)
      |> assign(:key_px, key_px)
      |> assign(:cols, cols)

    ~H"""
    <div class="space-y-4">
      <div class="flex gap-1 items-start">
        <div :for={strip <- Enum.filter(@strips, &(&1.id == :left_strip))}>
          <.fallback_cell
            control={strip}
            bindings={@bindings}
            selected={@selected}
            style={"width: #{strip.display.width}px; height: #{strip.display.height}px"}
          />
        </div>

        <div class="grid gap-1" style={"grid-template-columns: repeat(#{@cols}, #{@key_px}px)"}>
          <.fallback_cell
            :for={key <- @keys}
            control={key}
            bindings={@bindings}
            selected={@selected}
            style={"width: #{@key_px}px; height: #{@key_px}px"}
          />
        </div>

        <div :for={strip <- Enum.filter(@strips, &(&1.id == :right_strip))}>
          <.fallback_cell
            control={strip}
            bindings={@bindings}
            selected={@selected}
            style={"width: #{strip.display.width}px; height: #{strip.display.height}px"}
          />
        </div>
      </div>

      <div class="flex gap-1">
        <.fallback_cell
          :for={btn <- @buttons}
          control={btn}
          bindings={@bindings}
          selected={@selected}
          style={"width: #{round(@key_px * 0.6)}px; height: #{round(@key_px * 0.4)}px"}
        />
      </div>

      <div class="flex gap-2">
        <.fallback_cell
          :for={knob <- @knobs}
          control={knob}
          bindings={@bindings}
          selected={@selected}
          style={"width: #{round(@key_px * 0.55)}px; height: #{round(@key_px * 0.55)}px"}
          class="!rounded-full"
        />
      </div>
    </div>
    """
  end

  attr :control, :map, required: true
  attr :bindings, :map, required: true
  attr :selected, :any, default: nil
  attr :class, :string, default: ""
  attr :style, :string, default: ""

  defp fallback_cell(assigns) do
    ~H"""
    <button
      phx-click="select_control"
      phx-value-control={format_control_id(@control.id)}
      style={@style}
      class={[
        "border rounded text-center text-[9px] leading-tight flex items-center justify-center transition cursor-pointer",
        @class,
        status_class(@control.id, @bindings, @selected)
      ]}
    >
      {short_label(@control.id)}
    </button>
    """
  end

  # -- Helpers --

  defp status_class(control_id, bindings, selected) do
    cond do
      selected == control_id ->
        "border-blue-400 bg-blue-900/50 text-blue-300"

      Map.has_key?(bindings, format_control_id(control_id)) ->
        "border-green-600 bg-green-900/30 text-green-400"

      true ->
        "border-gray-600 bg-gray-700/50 text-gray-500 hover:border-gray-400"
    end
  end

  defp shape_class(:round), do: "rounded-full"
  defp shape_class(:pill), do: "rounded-xl"
  defp shape_class(:rect), do: "rounded"
  defp shape_class(_), do: "rounded"

  defp key_control?(%{id: {:key, _}, display: %{width: w, height: h}}) when w == h, do: true
  defp key_control?(_), do: false

  defp knob_control?(%{capabilities: caps}), do: MapSet.member?(caps, :rotate)
  defp knob_control?(_), do: false

  defp button_control?(%{id: {:button, _}}), do: true
  defp button_control?(_), do: false

  defp strip_control?(%{id: id}) when id in [:left_strip, :right_strip], do: true
  defp strip_control?(_), do: false

  def format_control_id({type, num}), do: "{:#{type}, #{num}}"
  def format_control_id(atom) when is_atom(atom), do: Atom.to_string(atom)
  def format_control_id(other), do: inspect(other)

  # Parse control_id strings (from `phx-value-control` params) back to the
  # atom/tuple form used internally. Uses `String.to_existing_atom/1` since
  # all legitimate control_ids are defined by a variant's `device_spec/0`
  # at compile time; an unexpected or malformed value falls back to the raw
  # string so downstream `Spec.find_control/2` returns nil and the event is
  # gracefully ignored. Prevents atom-table exhaustion from arbitrary input
  # over the LiveView channel. Mirrors `Loupey.Profiles.parse_control_id/1`.
  def parse_control_id(str) do
    case Regex.run(~r/^\{:(\w+), (\d+)\}$/, str) do
      [_, type, num] -> {String.to_existing_atom(type), String.to_integer(num)}
      _ -> String.to_existing_atom(str)
    end
  rescue
    ArgumentError -> str
  end

  defp short_label({:key, n}), do: "K#{n}"
  defp short_label({:button, n}), do: "B#{n}"
  defp short_label(:left_strip), do: "L"
  defp short_label(:right_strip), do: "R"
  defp short_label(:knob_tl), do: "TL"
  defp short_label(:knob_tr), do: "TR"
  defp short_label(:knob_cl), do: "CL"
  defp short_label(:knob_cr), do: "CR"
  defp short_label(:knob_bl), do: "BL"
  defp short_label(:knob_br), do: "BR"
  defp short_label(id), do: format_control_id(id)
end
