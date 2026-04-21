defmodule LoupeyWeb.ConditionBuilder do
  @moduledoc """
  LiveComponent that provides a structured UI for building expressions.

  Instead of typing raw expressions like `state_of("light.office") == "on"`,
  the user selects from dropdowns: entity, property, operator, value.

  Can also insert `{{ state_of("...") }}` templates into text fields.

  Sends `{:condition_built, id, expression_string}` to the parent.
  """
  use LoupeyWeb, :live_component

  @operators [
    {"equals", "=="},
    {"not equals", "!="},
    {"greater than", ">"},
    {"less than", "<"},
    {"contains", "=~"}
  ]

  @impl true
  def update(assigns, socket) do
    first_mount = !socket.assigns[:initialized]
    prev_value = socket.assigns[:current_value]
    new_value = assigns[:value] || prev_value || ""
    value_changed = prev_value != new_value

    parsed =
      if (first_mount or value_changed) and new_value != "",
        do: parse_expression(new_value),
        else: nil

    {:ok,
     socket
     |> assign(:initialized, true)
     |> assign(:component_id, assigns[:id])
     |> assign(:mode, assigns[:mode] || :condition)
     |> assign(:current_value, new_value)
     |> assign_parsed_fields(parsed)
     |> assign(:entity_matches, socket.assigns[:entity_matches] || [])
     |> assign(:show_entity_dropdown, socket.assigns[:show_entity_dropdown] || false)
     |> assign(:operators, @operators)}
  end

  defp assign_parsed_fields(socket, nil) do
    socket
    |> assign(:raw_mode, socket.assigns[:raw_mode] || false)
    |> assign(:entity, socket.assigns[:entity] || "")
    |> assign(:property, socket.assigns[:property] || "state")
    |> assign(:operator, socket.assigns[:operator] || "==")
    |> assign(:compare_value, socket.assigns[:compare_value] || "")
    |> assign(:attr_name, socket.assigns[:attr_name] || "")
  end

  defp assign_parsed_fields(socket, parsed) do
    socket
    |> assign(:raw_mode, parsed.raw)
    |> assign(:entity, parsed.entity)
    |> assign(:property, parsed.property)
    |> assign(:operator, parsed.operator)
    |> assign(:compare_value, parsed.compare_value)
    |> assign(:attr_name, parsed[:attr_name] || "")
  end

  # Parse an expression string back into builder fields
  defp parse_expression("true"),
    do: %{entity: "", property: "state", operator: "==", compare_value: "", raw: false}

  defp parse_expression(""), do: nil

  defp parse_expression(expr) do
    # Try to match: state_of("entity") op "value"
    expr = String.trim(expr)

    with :error <- parse_state_of_expr(expr),
         :error <- parse_attr_of_expr(expr) do
      %{entity: "", property: "state", operator: "==", compare_value: "", raw: true}
    end
  end

  defp parse_state_of_expr(expr) do
    case Regex.run(~r/^state_of\("([^"]+)"\)\s*(==|!=|>|<|=~)\s*"?([^"]*)"?\s*$/, expr) do
      [_, entity, op, value] ->
        %{entity: entity, property: "state", operator: op, compare_value: value, raw: false}

      nil ->
        :error
    end
  end

  defp parse_attr_of_expr(expr) do
    case Regex.run(
           ~r/^attr_of\("([^"]+)",\s*"([^"]+)"\)\s*(==|!=|>|<|=~)\s*"?([^"]*)"?\s*$/,
           expr
         ) do
      [_, entity, attr, op, value] ->
        %{
          entity: entity,
          property: "attribute",
          operator: op,
          compare_value: value,
          attr_name: attr,
          raw: false
        }

      nil ->
        :error
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-1.5">
      <%!-- Toggle between builder and raw --%>
      <div class="flex items-center justify-between">
        <label class="text-[10px] text-gray-500">
          {if @mode == :condition, do: "Condition", else: "Insert entity value"}
        </label>
        <button
          type="button"
          phx-click="toggle_raw"
          phx-target={@myself}
          class="text-[9px] text-gray-500 hover:text-gray-300"
        >
          {if @raw_mode, do: "Builder", else: "Raw"}
        </button>
      </div>

      <%!-- Raw expression mode --%>
      <div :if={@raw_mode}>
        <input
          type="text"
          phx-change="raw_change"
          phx-debounce="300"
          phx-target={@myself}
          name="raw_expr"
          value={@current_value}
          placeholder={if @mode == :condition, do: "e.g. state_of(\"light.x\") == \"on\"", else: "{{ state_of(\"sensor.temp\") }}°F"}
          class="w-full bg-gray-700 border border-gray-600 rounded px-1.5 py-1 text-xs text-white font-mono"
        />
      </div>

      <%!-- Builder mode --%>
      <div :if={!@raw_mode} class="space-y-1">
        <%!-- Entity picker --%>
        <div class="relative">
          <input
            type="text"
            phx-keyup="entity_search"
            phx-focus="entity_focus"
            phx-blur="entity_blur"
            phx-debounce="100"
            phx-target={@myself}
            value={@entity}
            placeholder="Select entity..."
            autocomplete="off"
            class="w-full bg-gray-700 border border-gray-600 rounded px-1.5 py-0.5 text-[10px] text-white"
          />
          <div
            :if={@show_entity_dropdown and @entity_matches != []}
            class="absolute z-10 w-full mt-0.5 bg-gray-900 border border-gray-600 rounded max-h-32 overflow-y-auto shadow-lg"
          >
            <button
              :for={id <- @entity_matches}
              type="button"
              phx-click="pick_entity"
              phx-target={@myself}
              phx-value-entity={id}
              class="block w-full text-left text-[10px] text-gray-300 hover:text-white hover:bg-gray-700 px-2 py-0.5 truncate"
            >
              {id}
            </button>
          </div>
        </div>

        <%!-- Property + Operator + Value (for condition mode) --%>
        <div :if={@mode == :condition and @entity != ""} class="grid grid-cols-3 gap-1">
          <select
            phx-change="set_property"
            phx-target={@myself}
            name="property"
            class="bg-gray-700 border border-gray-600 rounded px-1 py-0.5 text-[10px] text-white"
          >
            <option value="state" selected={@property == "state"}>state</option>
            <option value="attribute" selected={@property == "attribute"}>attribute...</option>
          </select>
          <select
            phx-change="set_operator"
            phx-target={@myself}
            name="operator"
            class="bg-gray-700 border border-gray-600 rounded px-1 py-0.5 text-[10px] text-white"
          >
            <option :for={{label, val} <- @operators} value={val} selected={val == @operator}>{label}</option>
          </select>
          <input
            type="text"
            phx-change="set_value"
            phx-debounce="200"
            phx-target={@myself}
            name="compare_value"
            value={@compare_value}
            placeholder="value"
            class="bg-gray-700 border border-gray-600 rounded px-1 py-0.5 text-[10px] text-white"
          />
        </div>

        <%!-- Attribute name (if property is attribute) --%>
        <div :if={@mode == :condition and @property == "attribute"}>
          <input
            type="text"
            phx-change="set_attr_name"
            phx-debounce="200"
            phx-target={@myself}
            name="attr_name"
            value={assigns[:attr_name] || ""}
            placeholder="attribute name (e.g. brightness)"
            class="w-full bg-gray-700 border border-gray-600 rounded px-1 py-0.5 text-[10px] text-white"
          />
        </div>

        <%!-- Apply button --%>
        <button
          :if={@entity != ""}
          type="button"
          phx-click="apply"
          phx-target={@myself}
          class="w-full bg-blue-700 hover:bg-blue-600 text-white text-[10px] px-2 py-1 rounded"
        >
          {if @mode == :condition, do: "Set condition", else: "Insert"}
        </button>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("toggle_raw", _params, socket) do
    {:noreply, assign(socket, raw_mode: !socket.assigns.raw_mode)}
  end

  def handle_event("raw_change", %{"raw_expr" => expr}, socket) do
    send(self(), {:condition_built, socket.assigns.component_id, expr})
    {:noreply, assign(socket, current_value: expr)}
  end

  def handle_event("entity_search", %{"value" => query}, socket) do
    matches = search_entities(query)

    {:noreply,
     assign(socket, entity: query, entity_matches: matches, show_entity_dropdown: matches != [])}
  end

  def handle_event("entity_focus", _params, socket) do
    matches = search_entities(socket.assigns.entity)
    {:noreply, assign(socket, show_entity_dropdown: matches != [], entity_matches: matches)}
  end

  def handle_event("entity_blur", _params, socket) do
    Process.send_after(self(), {:hide_dropdown, socket.assigns.component_id}, 200)
    {:noreply, socket}
  end

  def handle_event("pick_entity", %{"entity" => entity_id}, socket) do
    {:noreply, assign(socket, entity: entity_id, entity_matches: [], show_entity_dropdown: false)}
  end

  def handle_event("set_property", %{"property" => prop}, socket) do
    {:noreply, assign(socket, property: prop)}
  end

  def handle_event("set_operator", %{"operator" => op}, socket) do
    {:noreply, assign(socket, operator: op)}
  end

  def handle_event("set_value", %{"compare_value" => val}, socket) do
    {:noreply, assign(socket, compare_value: val)}
  end

  def handle_event("set_attr_name", %{"attr_name" => name}, socket) do
    {:noreply, assign(socket, attr_name: name)}
  end

  def handle_event("apply", _params, socket) do
    expr = build_expression(socket.assigns)
    send(self(), {:condition_built, socket.assigns.component_id, expr})
    {:noreply, assign(socket, current_value: expr)}
  end

  # -- Expression building --

  defp build_expression(%{mode: :condition} = assigns) do
    entity = assigns.entity
    property = assigns.property
    operator = assigns.operator
    value = assigns.compare_value

    left =
      case property do
        "state" -> "state_of(\"#{entity}\")"
        "attribute" -> "attr_of(\"#{entity}\", \"#{assigns[:attr_name] || ""}\")"
        _ -> "state_of(\"#{entity}\")"
      end

    quoted_value =
      case Float.parse(value) do
        {_num, ""} -> value
        _ -> "\"#{value}\""
      end

    "#{left} #{operator} #{quoted_value}"
  end

  defp build_expression(%{mode: :insert} = assigns) do
    entity = assigns.entity

    case assigns.property do
      "attribute" -> "{{ attr_of(\"#{entity}\", \"#{assigns[:attr_name] || ""}\") }}"
      _ -> "{{ state_of(\"#{entity}\") }}"
    end
  end

  defp build_expression(_), do: ""

  defp search_entities(query) when byte_size(query) >= 1 do
    Loupey.HA.get_all_states()
    |> Enum.map(& &1.entity_id)
    |> Enum.filter(&String.contains?(&1, query))
    |> Enum.sort()
    |> Enum.take(15)
  rescue
    _ -> []
  end

  defp search_entities(_), do: []
end
