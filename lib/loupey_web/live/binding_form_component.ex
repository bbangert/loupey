defmodule LoupeyWeb.BindingFormComponent do
  @moduledoc """
  Visual binding configurator that generates YAML.

  Provides form-based editing of input rules and output rules
  without requiring the user to write YAML directly.
  """

  use LoupeyWeb, :live_component

  @trigger_options [
    {"Press", "press"},
    {"Release", "release"},
    {"Rotate CW", "rotate_cw"},
    {"Rotate CCW", "rotate_ccw"},
    {"Touch Start", "touch_start"},
    {"Touch Move", "touch_move"},
    {"Touch End", "touch_end"}
  ]

  @action_options [
    {"Call Service", "call_service"},
    {"Switch Layout", "switch_layout"}
  ]

  @direction_options [
    {"Bottom to Top", "to_top"},
    {"Top to Bottom", "to_bottom"},
    {"Left to Right", "to_right"},
    {"Right to Left", "to_left"}
  ]

  @valign_options [
    {"Top", "top"},
    {"Middle", "middle"},
    {"Bottom", "bottom"}
  ]

  @impl true
  def update(assigns, socket) do
    first_mount = !socket.assigns[:form_data]

    # Track the yaml the parent gave us so we can detect when the user
    # selects a different control (yaml changes externally).
    prev_yaml = socket.assigns[:parent_yaml]
    new_yaml = assigns[:yaml] || prev_yaml || ""
    yaml_changed = prev_yaml != new_yaml

    form_data =
      if first_mount or yaml_changed do
        parse_yaml_to_form(new_yaml)
      else
        socket.assigns.form_data
      end

    socket =
      socket
      |> assign(:parent_yaml, new_yaml)
      |> assign(:entity_id, assigns[:entity_id] || socket.assigns[:entity_id])
      |> assign(:editing, assigns[:editing] || false)
      |> assign(:icon_browser_idx, socket.assigns[:icon_browser_idx])
      |> assign(:icon_files, socket.assigns[:icon_files] || [])
      |> assign(
        form_data: form_data,
        trigger_options: @trigger_options,
        action_options: @action_options,
        direction_options: @direction_options,
        valign_options: @valign_options
      )

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-4">
      <%!-- Input Rules Section --%>
      <div>
        <div class="flex items-center justify-between mb-2">
          <h3 class="text-xs font-semibold text-gray-400 uppercase">Input Rules</h3>
          <button
            phx-click="add_input_rule"
            phx-target={@myself}
            class="text-[10px] bg-gray-700 hover:bg-gray-600 text-white px-2 py-0.5 rounded"
          >
            + Add
          </button>
        </div>
        <div :for={{rule, idx} <- Enum.with_index(@form_data.input_rules)} class="bg-gray-900 rounded p-2 mb-2 space-y-2">
          <div class="flex items-center justify-between">
            <span class="text-[10px] text-gray-500">Rule {idx + 1}</span>
            <button
              phx-click="remove_input_rule"
              phx-target={@myself}
              phx-value-idx={idx}
              class="text-[10px] text-red-400 hover:text-red-300"
            >
              Remove
            </button>
          </div>
          <div class="grid grid-cols-2 gap-2">
            <div>
              <label class="text-[10px] text-gray-500">Trigger</label>
              <select
                phx-change="update_input_rule"
                phx-target={@myself}
                name={"input_rule[#{idx}][on]"}
                class="w-full bg-gray-700 border border-gray-600 rounded px-1.5 py-1 text-xs text-white"
              >
                <option :for={{label, val} <- @trigger_options} value={val} selected={val == rule.on}>
                  {label}
                </option>
              </select>
            </div>
            <div>
              <label class="text-[10px] text-gray-500">Action</label>
              <select
                phx-change="update_input_rule"
                phx-target={@myself}
                name={"input_rule[#{idx}][action]"}
                class="w-full bg-gray-700 border border-gray-600 rounded px-1.5 py-1 text-xs text-white"
              >
                <option :for={{label, val} <- @action_options} value={val} selected={val == rule.action}>
                  {label}
                </option>
              </select>
            </div>
          </div>
          <%!-- Service call fields --%>
          <div :if={rule.action == "call_service"} class="grid grid-cols-2 gap-2">
            <div>
              <label class="text-[10px] text-gray-500">Domain</label>
              <input
                type="text"
                phx-change="update_input_rule" phx-debounce="300"
                phx-target={@myself}
                name={"input_rule[#{idx}][domain]"}
                value={rule.domain}
                placeholder="light"
                class="w-full bg-gray-700 border border-gray-600 rounded px-1.5 py-1 text-xs text-white"
              />
            </div>
            <div>
              <label class="text-[10px] text-gray-500">Service</label>
              <input
                type="text"
                phx-change="update_input_rule" phx-debounce="300"
                phx-target={@myself}
                name={"input_rule[#{idx}][service]"}
                value={rule.service}
                placeholder="toggle"
                class="w-full bg-gray-700 border border-gray-600 rounded px-1.5 py-1 text-xs text-white"
              />
            </div>
          </div>
          <%!-- Service data --%>
          <div :if={rule.action == "call_service"}>
            <label class="text-[10px] text-gray-500">Service Data (YAML, optional)</label>
            <textarea
              phx-change="update_input_rule" phx-debounce="300"
              phx-target={@myself}
              name={"input_rule[#{idx}][service_data]"}
              rows="2"
              placeholder={"brightness: 128\ncolor_temp: 400"}
              class="w-full bg-gray-700 border border-gray-600 rounded px-1.5 py-1 text-xs text-white font-mono resize-y"
            >{format_service_data(rule[:service_data])}</textarea>
          </div>
          <%!-- Condition --%>
          <div>
            <label class="text-[10px] text-gray-500">Condition (optional)</label>
            <input
              type="text"
              phx-change="update_input_rule" phx-debounce="300"
              phx-target={@myself}
              name={"input_rule[#{idx}][when]"}
              value={rule[:when] || ""}
              placeholder={~s(e.g. state == "on")}
              class="w-full bg-gray-700 border border-gray-600 rounded px-1.5 py-1 text-xs text-white font-mono"
            />
          </div>
          <%!-- Switch layout field --%>
          <div :if={rule.action == "switch_layout"}>
            <label class="text-[10px] text-gray-500">Layout name</label>
            <input
              type="text"
              phx-change="update_input_rule" phx-debounce="300"
              phx-target={@myself}
              name={"input_rule[#{idx}][layout]"}
              value={rule[:layout] || ""}
              placeholder="media"
              class="w-full bg-gray-700 border border-gray-600 rounded px-1.5 py-1 text-xs text-white"
            />
          </div>
        </div>
      </div>

      <%!-- Output Rules Section --%>
      <div>
        <div class="flex items-center justify-between mb-2">
          <h3 class="text-xs font-semibold text-gray-400 uppercase">Output Rules</h3>
          <button
            phx-click="add_output_rule"
            phx-target={@myself}
            class="text-[10px] bg-gray-700 hover:bg-gray-600 text-white px-2 py-0.5 rounded"
          >
            + Add
          </button>
        </div>
        <form
          :for={{rule, idx} <- Enum.with_index(@form_data.output_rules)}
          phx-change="update_output_form"
          phx-target={@myself}
          class="bg-gray-900 rounded p-2 mb-2 space-y-2"
        >
          <input type="hidden" name="idx" value={idx} />
          <div class="flex items-center justify-between">
            <span class="text-[10px] text-gray-500">Rule {idx + 1}</span>
            <button
              type="button"
              phx-click="remove_output_rule"
              phx-target={@myself}
              phx-value-idx={idx}
              class="text-[10px] text-red-400 hover:text-red-300"
            >
              Remove
            </button>
          </div>
          <%!-- Condition --%>
          <div>
            <label class="text-[10px] text-gray-500">Condition</label>
            <input
              type="text"
              name="when"
              value={format_when(rule[:when])}
              phx-debounce="300"
              placeholder={~s(e.g. state == "on"  or  true)}
              class="w-full bg-gray-700 border border-gray-600 rounded px-1.5 py-1 text-xs text-white font-mono"
            />
          </div>
          <div class="grid grid-cols-2 gap-2">
            <div>
              <label class="text-[10px] text-gray-500">Background</label>
              <input type="color" name="background" value={rule[:background] || "#000000"}
                class="w-full h-7 bg-gray-700 border border-gray-600 rounded cursor-pointer"
              />
            </div>
            <div>
              <label class="text-[10px] text-gray-500">LED Color</label>
              <input type="color" name="color" value={rule[:color] || "#ffffff"}
                class="w-full h-7 bg-gray-700 border border-gray-600 rounded cursor-pointer"
              />
            </div>
          </div>
          <%!-- Icon --%>
          <div>
            <label class="text-[10px] text-gray-500">Icon</label>
            <div class="flex gap-1">
              <input
                type="text"
                name="icon"
                value={rule[:icon] || ""}
                phx-debounce="300"
                placeholder="Click Browse to select"
                readonly
                class="flex-1 bg-gray-700 border border-gray-600 rounded px-1.5 py-1 text-xs text-white truncate"
              />
              <button
                type="button"
                phx-click="toggle_icon_browser"
                phx-target={@myself}
                phx-value-idx={idx}
                class="text-[10px] bg-gray-600 hover:bg-gray-500 text-white px-2 py-1 rounded whitespace-nowrap"
              >
                Browse
              </button>
              <button
                :if={rule[:icon] && rule[:icon] != ""}
                type="button"
                phx-click="clear_icon"
                phx-target={@myself}
                phx-value-idx={idx}
                class="text-[10px] bg-gray-700 hover:bg-gray-600 text-red-400 px-1.5 py-1 rounded"
              >
                ✕
              </button>
            </div>
            <%!-- Icon browser --%>
            <div :if={@icon_browser_idx == idx} class="mt-1 bg-gray-900 border border-gray-600 rounded-lg p-2 max-h-52 overflow-y-auto">
              <div :if={@icon_files == []} class="text-xs text-gray-500 p-2">No icons found</div>
              <div class="grid grid-cols-4 gap-1">
                <button
                  :for={icon <- @icon_files}
                  type="button"
                  phx-click="pick_icon"
                  phx-target={@myself}
                  phx-value-path={icon.path}
                  phx-value-idx={idx}
                  class={[
                    "flex flex-col items-center p-1 rounded hover:bg-gray-700 transition",
                    if(rule[:icon] == icon.path, do: "bg-gray-700 ring-1 ring-blue-400", else: "")
                  ]}
                >
                  <img src={"/icons/#{icon.relative}"} class="w-10 h-10 object-contain" />
                  <span class="text-[8px] text-gray-400 truncate w-full text-center mt-0.5">{icon.name}</span>
                </button>
              </div>
            </div>
          </div>
          <%!-- Fill --%>
          <div class="grid grid-cols-3 gap-2">
            <div>
              <label class="text-[10px] text-gray-500">Fill amount</label>
              <input
                type="text"
                name="fill_amount"
                value={get_in(rule, [:fill, :amount]) || ""}
                phx-debounce="300"
                placeholder="50 or {{ expr }}"
                class="w-full bg-gray-700 border border-gray-600 rounded px-1.5 py-1 text-xs text-white"
              />
            </div>
            <div>
              <label class="text-[10px] text-gray-500">Direction</label>
              <select name="fill_direction"
                class="w-full bg-gray-700 border border-gray-600 rounded px-1.5 py-1 text-xs text-white"
              >
                <option value="">None</option>
                <option :for={{label, val} <- @direction_options} value={val} selected={val == to_string(get_in(rule, [:fill, :direction]) || "")}>
                  {label}
                </option>
              </select>
            </div>
            <div>
              <label class="text-[10px] text-gray-500">Fill color</label>
              <input type="color" name="fill_color" value={get_in(rule, [:fill, :color]) || "#ffffff"}
                class="w-full h-7 bg-gray-700 border border-gray-600 rounded cursor-pointer"
              />
            </div>
          </div>
          <%!-- Text --%>
          <div class="grid grid-cols-4 gap-2">
            <div class="col-span-2">
              <label class="text-[10px] text-gray-500">Text</label>
              <textarea
                name="text_content"
                rows="2"
                phx-debounce="300"
                placeholder="ON or {{ state }}°F"
                class="w-full bg-gray-700 border border-gray-600 rounded px-1.5 py-1 text-xs text-white font-mono resize-y"
              >{get_text_content(rule[:text]) || ""}</textarea>
            </div>
            <div>
              <label class="text-[10px] text-gray-500">Text color</label>
              <input type="color" name="text_color" value={get_text_color(rule[:text])}
                class="w-full h-7 bg-gray-700 border border-gray-600 rounded cursor-pointer"
              />
            </div>
            <div>
              <label class="text-[10px] text-gray-500">Align</label>
              <select name="text_valign"
                class="w-full bg-gray-700 border border-gray-600 rounded px-1.5 py-1 text-xs text-white"
              >
                <option :for={{label, val} <- @valign_options} value={val} selected={val == to_string(get_text_valign(rule[:text]))}>
                  {label}
                </option>
              </select>
            </div>
          </div>
        </form>
      </div>

      <%!-- Save / Delete buttons --%>
      <div class="flex gap-2">
        <button
          phx-click="save_from_visual"
          phx-target={@myself}
          class="flex-1 bg-blue-600 hover:bg-blue-500 text-white text-xs px-3 py-2 rounded-lg"
        >
          Save Binding
        </button>
        <button
          :if={@editing}
          phx-click="delete_binding"
          phx-target={@myself}
          data-confirm="Remove this binding?"
          class="bg-red-900 hover:bg-red-800 text-red-300 text-xs px-3 py-2 rounded-lg"
        >
          Remove
        </button>
      </div>
    </div>
    """
  end

  # -- Events --

  @impl true
  def handle_event("add_input_rule", _params, socket) do
    form_data = socket.assigns.form_data
    new_rule = %{on: "press", action: "call_service", domain: "", service: ""}
    form_data = %{form_data | input_rules: form_data.input_rules ++ [new_rule]}
    {:noreply, assign(socket, form_data: form_data)}
  end

  def handle_event("remove_input_rule", %{"idx" => idx}, socket) do
    form_data = socket.assigns.form_data
    rules = List.delete_at(form_data.input_rules, String.to_integer(idx))
    {:noreply, assign(socket, form_data: %{form_data | input_rules: rules})}
  end

  def handle_event("update_input_rule", params, socket) do
    form_data = socket.assigns.form_data

    case extract_rule_param(params, "input_rule") do
      {:ok, idx, :service_data, value} ->
        rules = List.update_at(form_data.input_rules, idx, &Map.put(&1, :service_data, parse_service_data(value)))
        {:noreply, assign(socket, form_data: %{form_data | input_rules: rules})}

      {:ok, idx, field, value} ->
        rules = List.update_at(form_data.input_rules, idx, &Map.put(&1, field, value))
        {:noreply, assign(socket, form_data: %{form_data | input_rules: rules})}

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("add_output_rule", _params, socket) do
    form_data = socket.assigns.form_data
    new_rule = %{when: "true", background: "#111111"}
    form_data = %{form_data | output_rules: form_data.output_rules ++ [new_rule]}
    {:noreply, assign(socket, form_data: form_data)}
  end

  def handle_event("remove_output_rule", %{"idx" => idx}, socket) do
    form_data = socket.assigns.form_data
    rules = List.delete_at(form_data.output_rules, String.to_integer(idx))
    {:noreply, assign(socket, form_data: %{form_data | output_rules: rules})}
  end

  def handle_event("update_output_form", params, socket) do
    idx = String.to_integer(params["idx"])
    form_data = socket.assigns.form_data
    rules = List.update_at(form_data.output_rules, idx, &update_output_rule(&1, params))
    {:noreply, assign(socket, form_data: %{form_data | output_rules: rules})}
  end

  def handle_event("toggle_icon_browser", %{"idx" => idx_str}, socket) do
    idx = String.to_integer(idx_str)

    if socket.assigns.icon_browser_idx == idx do
      {:noreply, assign(socket, icon_browser_idx: nil)}
    else
      icon_files = scan_icons()
      {:noreply, assign(socket, icon_browser_idx: idx, icon_files: icon_files)}
    end
  end

  def handle_event("pick_icon", %{"path" => path, "idx" => idx_str}, socket) do
    idx = String.to_integer(idx_str)
    form_data = socket.assigns.form_data

    rules =
      List.update_at(form_data.output_rules, idx, fn rule ->
        Map.put(rule, :icon, path)
      end)

    {:noreply,
     assign(socket,
       form_data: %{form_data | output_rules: rules},
       icon_browser_idx: nil
     )}
  end

  def handle_event("clear_icon", %{"idx" => idx_str}, socket) do
    idx = String.to_integer(idx_str)
    form_data = socket.assigns.form_data

    rules =
      List.update_at(form_data.output_rules, idx, fn rule ->
        Map.delete(rule, :icon)
      end)

    {:noreply, assign(socket, form_data: %{form_data | output_rules: rules})}
  end

  def handle_event("save_from_visual", _params, socket) do
    yaml = form_to_yaml(socket.assigns.form_data, socket.assigns[:entity_id])
    send(self(), {:save_binding_yaml, yaml})
    {:noreply, socket}
  end

  def handle_event("delete_binding", _params, socket) do
    send(self(), :delete_binding)
    {:noreply, socket}
  end

  # -- Output form helpers --

  defp update_output_rule(rule, params) do
    rule
    |> put_if_present(:when, parse_when_value(params["when"]))
    |> put_if_present(:background, params["background"])
    |> put_if_present(:color, params["color"])
    |> put_if_present(:icon, params["icon"])
    |> update_fill(params)
    |> update_text(params)
  end

  defp update_fill(rule, params) do
    amount = params["fill_amount"]
    dir = params["fill_direction"]
    color = params["fill_color"]

    if (amount && amount != "") or (dir && dir != "") do
      fill = %{}
      fill = if amount != "", do: Map.put(fill, :amount, amount), else: fill
      fill = if dir != "", do: Map.put(fill, :direction, dir), else: fill
      fill = if color, do: Map.put(fill, :color, color), else: fill
      Map.put(rule, :fill, fill)
    else
      Map.delete(rule, :fill)
    end
  end

  defp update_text(rule, params) do
    content = params["text_content"]
    valign = params["text_valign"]
    color = params["text_color"]

    if content && content != "" do
      text = %{content: content}
      text = if valign && valign != "", do: Map.put(text, :valign, valign), else: text
      text = if color && color != "", do: Map.put(text, :color, color), else: text
      Map.put(rule, :text, text)
    else
      Map.delete(rule, :text)
    end
  end

  defp put_if_present(rule, _key, nil), do: rule
  defp put_if_present(rule, _key, ""), do: rule
  defp put_if_present(rule, key, value), do: Map.put(rule, key, value)

  defp parse_when_value(nil), do: nil
  defp parse_when_value("true"), do: true
  defp parse_when_value(""), do: true
  defp parse_when_value(expr), do: expr

  # -- YAML generation --

  defp form_to_yaml(form_data, entity_id) do
    parts =
      if entity_id && entity_id != "",
        do: ["entity_id: \"#{entity_id}\""],
        else: []

    parts = parts ++ ["input_rules:"] ++ input_rules_to_yaml(form_data.input_rules, entity_id)
    parts = parts ++ ["output_rules:"] ++ output_rules_to_yaml(form_data.output_rules)

    Enum.join(parts, "\n") <> "\n"
  end

  defp input_rules_to_yaml([], _entity_id), do: ["  []"]

  defp input_rules_to_yaml(rules, entity_id) do
    Enum.flat_map(rules, &input_rule_to_yaml(&1, entity_id))
  end

  defp input_rule_to_yaml(rule, entity_id) do
    lines = ["  - on: #{rule.on}"]
    lines = if rule[:when] && rule[:when] != "", do: lines ++ ["    when: '#{rule[:when]}'"], else: lines
    lines = lines ++ ["    action: #{rule.action}"]
    lines = lines ++ input_action_yaml(rule, entity_id)
    lines
  end

  defp input_action_yaml(%{action: "call_service"} = rule, entity_id) do
    if_present("    domain: ", rule[:domain]) ++
      if_present("    service: ", rule[:service]) ++
      if(entity_id && entity_id != "", do: ["    target: \"#{entity_id}\""], else: []) ++
      service_data_to_yaml(rule[:service_data])
  end

  defp input_action_yaml(%{action: "switch_layout"} = rule, _entity_id) do
    if rule[:layout] && rule[:layout] != "",
      do: ["    layout: \"#{rule[:layout]}\""],
      else: []
  end

  defp input_action_yaml(_rule, _entity_id), do: []

  defp service_data_to_yaml(nil), do: []
  defp service_data_to_yaml(data) when data == %{}, do: []

  defp service_data_to_yaml(data) when is_map(data) do
    lines = Enum.flat_map(data, fn {k, v} ->
      str = to_string(v)
      val = if String.starts_with?(str, "{{") or String.starts_with?(str, "#"), do: "\"#{str}\"", else: str
      ["      #{k}: #{val}"]
    end)

    if lines != [], do: ["    service_data:"] ++ lines, else: []
  end

  defp output_rules_to_yaml([]), do: ["  []"]

  defp output_rules_to_yaml(rules) do
    Enum.flat_map(rules, &output_rule_to_yaml/1)
  end

  defp output_rule_to_yaml(rule) do
    lines = ["  - when: #{format_when_yaml(rule[:when])}"]
    lines = if_present(lines, "    background: ", rule[:background])
    lines = if_present(lines, "    color: ", rule[:color])
    lines = if_present(lines, "    icon: ", rule[:icon])
    lines = lines ++ fill_to_yaml(rule[:fill])
    lines ++ text_to_yaml(rule[:text])
  end

  defp fill_to_yaml(%{} = fill) when map_size(fill) > 0 do
    ["    fill:"] ++
      if_present("      amount: ", fill[:amount]) ++
      if_present("      direction: ", fill[:direction]) ++
      if_present("      color: ", fill[:color])
  end

  defp fill_to_yaml(_), do: []

  defp text_to_yaml(%{content: content} = text) when is_binary(content) and content != "" do
    escaped = content |> String.replace("\\", "\\\\") |> String.replace("\n", "\\n")
    ["    text:", "      content: \"#{escaped}\""] ++
      if_present("      valign: ", text[:valign]) ++
      if_present("      font_size: ", text[:font_size]) ++
      if_present("      color: ", text[:color])
  end

  defp text_to_yaml(_), do: []

  defp if_present(prefix, value) when is_binary(prefix) do
    if value && value != "" do
      str = to_string(value)
      # Quote values starting with # so YAML doesn't treat them as comments
      str = if String.starts_with?(str, "#"), do: "\"#{str}\"", else: str
      [prefix <> str]
    else
      []
    end
  end

  defp if_present(lines, prefix, value) do
    if value && value != "" do
      lines ++ ["#{prefix}\"#{value}\""]
    else
      lines
    end
  end

  defp format_when_yaml("true"), do: "true"
  defp format_when_yaml(nil), do: "true"
  defp format_when_yaml(expr), do: "'#{expr}'"

  # -- YAML parsing to form --

  defp parse_yaml_to_form(yaml) when yaml == "" or yaml == nil do
    %{input_rules: [], output_rules: []}
  end

  defp parse_yaml_to_form(yaml) do
    case YamlElixir.read_from_string(yaml) do
      {:ok, data} ->
        %{
          input_rules: parse_form_input_rules(data["input_rules"] || []),
          output_rules: parse_form_output_rules(data["output_rules"] || [])
        }

      _ ->
        %{input_rules: [], output_rules: []}
    end
  end

  defp parse_form_input_rules(rules) do
    Enum.map(rules, fn rule ->
      base = %{
        on: rule["on"] || "press",
        action: rule["action"] || "call_service",
        domain: rule["domain"] || "",
        service: rule["service"] || "",
        when: rule["when"],
        layout: rule["layout"]
      }

      if is_map(rule["service_data"]) and rule["service_data"] != %{},
        do: Map.put(base, :service_data, stringify_keys(rule["service_data"])),
        else: base
    end)
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), to_string(v)} end)
  end

  defp parse_form_output_rules(rules) do
    Enum.map(rules, &parse_form_output_rule/1)
  end

  defp parse_form_output_rule(rule) do
    %{when: rule["when"] || "true"}
    |> maybe_put(:background, rule["background"])
    |> maybe_put(:color, rule["color"])
    |> maybe_put(:icon, rule["icon"])
    |> parse_form_fill(rule["fill"])
    |> parse_form_text(rule["text"])
  end

  defp parse_form_fill(base, %{} = fill) do
    parsed =
      %{}
      |> maybe_put(:amount, fill["amount"])
      |> maybe_put(:direction, fill["direction"])
      |> maybe_put(:color, fill["color"])

    if parsed != %{}, do: Map.put(base, :fill, parsed), else: base
  end

  defp parse_form_fill(base, _), do: base

  defp parse_form_text(base, %{} = text) do
    parsed =
      %{content: text["content"]}
      |> maybe_put(:valign, text["valign"])
      |> maybe_put(:font_size, text["font_size"])
      |> maybe_put(:color, text["color"])

    Map.put(base, :text, parsed)
  end

  defp parse_form_text(base, _), do: base

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp extract_rule_param(params, prefix) do
    case params[prefix] do
      nil ->
        :error

      rule_map ->
        {idx_str, field_map} = Enum.find(rule_map, fn {_k, _v} -> true end)

        {field_str, value} = Enum.find(field_map, fn {_k, _v} -> true end)

        {:ok, String.to_integer(idx_str), String.to_atom(field_str), value}
    end
  end

  defp format_when(true), do: "true"
  defp format_when("true"), do: "true"
  defp format_when(nil), do: "true"
  defp format_when(expr), do: to_string(expr)

  defp get_text_content(%{content: c}), do: c
  defp get_text_content(text) when is_binary(text), do: text
  defp get_text_content(_), do: nil

  defp get_text_valign(%{valign: v}), do: v
  defp get_text_valign(_), do: "bottom"

  defp parse_service_data(text) when is_binary(text) do
    text
    |> String.split("\n")
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Map.new(fn line ->
      case String.split(line, ":", parts: 2) do
        [key, value] -> {String.trim(key), String.trim(value) |> String.trim("\"")}
        _ -> {"", ""}
      end
    end)
    |> Map.delete("")
  end

  defp parse_service_data(_), do: %{}

  defp format_service_data(nil), do: ""
  defp format_service_data(data) when data == %{}, do: ""

  defp format_service_data(data) when is_map(data) do
    data
    |> Enum.map(fn {k, v} -> "#{k}: #{format_sd_value(v)}" end)
    |> Enum.join("\n")
  end

  defp format_service_data(_), do: ""

  defp format_sd_value(v) when is_binary(v) and byte_size(v) > 0 do
    if String.starts_with?(v, "{{") or String.starts_with?(v, "#"),
      do: "\"#{v}\"",
      else: v
  end

  defp format_sd_value(v), do: inspect(v)

  defp get_text_color(%{color: c}) when not is_nil(c), do: c
  defp get_text_color(_), do: "#ffffff"

  @icons_dir Path.join(File.cwd!(), "icons")

  defp scan_icons do
    if File.dir?(@icons_dir) do
      @icons_dir
      |> scan_dir_recursive("")
      |> Enum.sort_by(& &1.name)
    else
      []
    end
  end

  defp scan_dir_recursive(base_dir, relative_prefix) do
    dir = if relative_prefix == "", do: base_dir, else: Path.join(base_dir, relative_prefix)

    case File.ls(dir) do
      {:ok, entries} ->
        Enum.flat_map(entries, &classify_entry(base_dir, relative_prefix, &1))

      _ ->
        []
    end
  end

  defp classify_entry(base_dir, prefix, entry) do
    relative = if prefix == "", do: entry, else: Path.join(prefix, entry)
    full_path = Path.join(base_dir, relative)

    cond do
      File.dir?(full_path) ->
        scan_dir_recursive(base_dir, relative)

      String.match?(entry, ~r/\.(png|jpg|jpeg|svg|gif)$/i) ->
        [%{name: Path.rootname(entry), path: Path.join("icons", relative), relative: relative}]

      true ->
        []
    end
  end
end
