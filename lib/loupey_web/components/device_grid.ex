defmodule LoupeyWeb.DeviceGrid do
  @moduledoc """
  Function component that renders a visual representation of a device's
  physical layout, with clickable controls that indicate binding status.
  """
  use Phoenix.Component

  @doc """
  Renders the device grid. Expects:
  - `spec` — `Loupey.Device.Spec` for layout dimensions
  - `bindings` — map of control_id_string => binding
  - `selected` — currently selected control_id or nil
  """
  def grid(assigns) do
    controls = assigns.spec.controls

    keys = controls |> Enum.filter(&key_control?/1) |> Enum.sort_by(&elem(&1.id, 1))
    knobs = Enum.filter(controls, &knob_control?/1)
    buttons = controls |> Enum.filter(&button_control?/1) |> Enum.sort_by(&elem(&1.id, 1))
    strips = Enum.filter(controls, &strip_control?/1)

    scale = 1
    key_size = if keys != [], do: hd(keys).display.width, else: 90
    cols = length(keys) |> div(3) |> max(1)

    assigns =
      assigns
      |> assign(:keys, keys)
      |> assign(:knobs, knobs)
      |> assign(:buttons, buttons)
      |> assign(:strips, strips)
      |> assign(:scale, scale)
      |> assign(:key_px, round(key_size * scale))
      |> assign(:cols, cols)

    ~H"""
    <div class="space-y-4">
      <div class="flex gap-1 items-start">
        <div :for={strip <- Enum.filter(@strips, &(&1.id == :left_strip))}>
          <.control_cell
            control={strip}
            bindings={@bindings}
            selected={@selected}
            style={"width: #{round(strip.display.width * @scale)}px; height: #{round(strip.display.height * @scale)}px"}
          />
        </div>

        <div class="grid gap-1" style={"grid-template-columns: repeat(#{@cols}, #{@key_px}px)"}>
          <.control_cell
            :for={key <- @keys}
            control={key}
            bindings={@bindings}
            selected={@selected}
            style={"width: #{@key_px}px; height: #{@key_px}px"}
          />
        </div>

        <div :for={strip <- Enum.filter(@strips, &(&1.id == :right_strip))}>
          <.control_cell
            control={strip}
            bindings={@bindings}
            selected={@selected}
            style={"width: #{round(strip.display.width * @scale)}px; height: #{round(strip.display.height * @scale)}px"}
          />
        </div>
      </div>

      <div class="flex gap-1">
        <.control_cell
          :for={btn <- @buttons}
          control={btn}
          bindings={@bindings}
          selected={@selected}
          style={"width: #{round(@key_px * 0.6)}px; height: #{round(@key_px * 0.4)}px"}
        />
      </div>

      <div class="flex gap-2">
        <.control_cell
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

  defp control_cell(assigns) do
    ~H"""
    <% has_binding = Map.has_key?(@bindings, format_control_id(@control.id)) %>
    <% is_selected = @selected == @control.id %>
    <button
      phx-click="select_control"
      phx-value-control={format_control_id(@control.id)}
      style={@style}
      class={[
        "border rounded text-center text-[9px] leading-tight flex items-center justify-center transition cursor-pointer",
        @class,
        cond do
          is_selected -> "border-blue-400 bg-blue-900/50 text-blue-300"
          has_binding -> "border-green-600 bg-green-900/30 text-green-400"
          true -> "border-gray-600 bg-gray-700/50 text-gray-500 hover:border-gray-400"
        end
      ]}
    >
      {short_label(@control.id)}
    </button>
    """
  end

  # -- Helpers --

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
  defp short_label(:knob_ct), do: "CT"
  defp short_label(:knob_tl), do: "TL"
  defp short_label(:knob_tr), do: "TR"
  defp short_label(:knob_cl), do: "CL"
  defp short_label(:knob_cr), do: "CR"
  defp short_label(:knob_bl), do: "BL"
  defp short_label(:knob_br), do: "BR"
  defp short_label(id), do: format_control_id(id)
end
