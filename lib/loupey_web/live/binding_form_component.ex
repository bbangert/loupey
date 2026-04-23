defmodule LoupeyWeb.BindingFormComponent do
  @moduledoc """
  Visual binding configurator that generates YAML.

  Provides form-based editing of input rules and output rules
  without requiring the user to write YAML directly.
  """

  use LoupeyWeb, :live_component

  alias Loupey.Bindings.FormCodec

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

    form_data = resolve_form_data(assigns, socket, first_mount, yaml_changed, new_yaml)

    socket =
      socket
      |> assign(:parent_yaml, new_yaml)
      |> assign(:entity_id, assigns[:entity_id] || socket.assigns[:entity_id])
      |> assign(:editing, assigns[:editing] || false)
      |> assign(:icon_browser_idx, socket.assigns[:icon_browser_idx])
      |> assign(:icon_files, socket.assigns[:icon_files] || [])
      |> assign(:control, assigns[:control] || socket.assigns[:control])
      |> assign_ha_services()
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
      <.input_rules_section
        form_data={@form_data}
        control={@control}
        action_options={@action_options}
        ha_domains={@ha_domains}
        ha_services={@ha_services}
        myself={@myself}
      />
      <.output_rules_section
        form_data={@form_data}
        direction_options={@direction_options}
        valign_options={@valign_options}
        icon_browser_idx={@icon_browser_idx}
        icon_files={@icon_files}
        myself={@myself}
      />
      <.save_delete_buttons editing={@editing} myself={@myself} />
    </div>
    """
  end

  # -- Function components --

  defp input_rules_section(assigns) do
    ~H"""
    <div>
      <div class="flex items-center justify-between mb-2">
        <h3 class="text-base font-semibold text-gray-400 uppercase">Input Rules</h3>
        <button
          phx-click="add_input_rule"
          phx-target={@myself}
          class="text-base bg-gray-700 hover:bg-gray-600 text-white px-2 py-0.5 rounded"
        >
          + Add
        </button>
      </div>
      <div :for={{rule, idx} <- Enum.with_index(@form_data.input_rules)} class="bg-gray-900 rounded p-2 mb-2 space-y-2">
        <div class="flex items-center justify-between">
          <span class="text-base text-gray-500">Rule {idx + 1}</span>
          <button
            phx-click="remove_input_rule"
            phx-target={@myself}
            phx-value-idx={idx}
            class="text-base text-red-400 hover:text-red-300"
          >
            Remove
          </button>
        </div>
        <form phx-change="update_input_rule_form" phx-target={@myself} class="grid grid-cols-2 gap-2">
          <input type="hidden" name="idx" value={idx} />
          <div>
            <label class="text-base text-gray-500">Trigger</label>
            <select
              name="on"
              class="w-full bg-gray-700 border border-gray-600 rounded px-1.5 py-1 text-base text-white"
            >
              <option :for={{label, val} <- trigger_options_for(@control)} value={val} selected={val == rule.on}>
                {label}
              </option>
            </select>
          </div>
          <div>
            <label class="text-base text-gray-500">Condition (optional)</label>
            <input
              type="text"
              name="when"
              value={rule[:when] || ""}
              phx-debounce="300"
              placeholder="e.g. state_of(...) == ..."
              class="w-full bg-gray-700 border border-gray-600 rounded px-1.5 py-1 text-base text-white font-mono"
            />
          </div>
        </form>
        <div class="ml-2 border-l-2 border-gray-700 pl-2 space-y-2">
          <div class="flex items-center gap-2">
            <span class="text-base text-gray-500 uppercase">Actions</span>
            <button
              phx-click="add_action"
              phx-target={@myself}
              phx-value-rule-idx={idx}
              class="text-base bg-gray-700 hover:bg-gray-600 text-white px-1.5 py-0.5 rounded"
            >
              + Add
            </button>
          </div>
          <.action_form
            :for={{action, aidx} <- Enum.with_index(rule.actions)}
            action={action}
            rule_idx={idx}
            action_idx={aidx}
            action_options={@action_options}
            ha_domains={@ha_domains}
            ha_services={@ha_services}
            myself={@myself}
          />
        </div>
      </div>
    </div>
    """
  end

  defp action_form(assigns) do
    ~H"""
    <form
      phx-change="update_action_form"
      phx-target={@myself}
      class="bg-gray-800 rounded p-1.5 space-y-1.5"
    >
      <input type="hidden" name="rule_idx" value={@rule_idx} />
      <input type="hidden" name="action_idx" value={@action_idx} />
      <div class="flex items-center justify-between">
        <select
          name="action_type"
          class="bg-gray-700 border border-gray-600 rounded px-1 py-0.5 text-base text-white"
        >
          <option :for={{label, val} <- @action_options} value={val} selected={val == @action[:action]}>
            {label}
          </option>
        </select>
        <button
          type="button"
          phx-click="remove_action"
          phx-target={@myself}
          phx-value-rule-idx={@rule_idx}
          phx-value-action-idx={@action_idx}
          class="text-base text-red-400 hover:text-red-300"
        >
          ✕
        </button>
      </div>
      <div :if={@action[:action] == "call_service"} class="grid grid-cols-2 gap-1">
        <div>
          <select
            name="domain"
            class="w-full bg-gray-700 border border-gray-600 rounded px-1 py-0.5 text-base text-white"
          >
            <option value="">Domain...</option>
            <option :for={d <- @ha_domains} value={d} selected={d == @action[:domain]}>{d}</option>
          </select>
        </div>
        <div>
          <%= if services_for_domain(@action[:domain], @ha_services) == [] do %>
            <input
              type="text"
              name="service"
              value={@action[:service] || ""}
              phx-debounce="300"
              placeholder="Service name (e.g. toggle)"
              class="w-full bg-gray-700 border border-gray-600 rounded px-1 py-0.5 text-base text-white"
            />
          <% else %>
            <select
              name="service"
              class="w-full bg-gray-700 border border-gray-600 rounded px-1 py-0.5 text-base text-white"
            >
              <option value="">Service...</option>
              <option :for={s <- services_for_domain(@action[:domain], @ha_services)} value={s} selected={s == @action[:service]}>{s}</option>
            </select>
          <% end %>
        </div>
      </div>
      <div :if={@action[:action] == "call_service"}>
        <label class="text-base text-gray-500">Target entity</label>
        <.live_component
          module={LoupeyWeb.EntityAutocomplete}
          id={"action_target_#{@rule_idx}_#{@action_idx}"}
          value={@action[:target] || ""}
          name="target"
          domain={@action[:domain]}
          placeholder={"entity_id (e.g. #{@action[:domain] || "light"}.office)"}
        />
      </div>
      <div :if={@action[:action] == "call_service"}>
        <textarea
          name="service_data"
          rows="1"
          phx-debounce="300"
          placeholder="key: value (one per line)"
          class="w-full bg-gray-700 border border-gray-600 rounded px-1 py-0.5 text-base text-white font-mono resize-y"
        >{format_service_data(@action[:service_data])}</textarea>
      </div>
      <div :if={@action[:action] == "switch_layout"}>
        <input
          type="text"
          name="layout"
          value={@action[:layout] || ""}
          phx-debounce="300"
          placeholder="Layout name"
          class="w-full bg-gray-700 border border-gray-600 rounded px-1 py-0.5 text-base text-white"
        />
      </div>
    </form>
    """
  end

  defp output_rules_section(assigns) do
    ~H"""
    <div>
      <div class="flex items-center justify-between mb-2">
        <h3 class="text-base font-semibold text-gray-400 uppercase">Output Rules</h3>
        <button
          phx-click="add_output_rule"
          phx-target={@myself}
          class="text-base bg-gray-700 hover:bg-gray-600 text-white px-2 py-0.5 rounded"
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
          <span class="text-base text-gray-500">Rule {idx + 1}</span>
          <button
            type="button"
            phx-click="remove_output_rule"
            phx-target={@myself}
            phx-value-idx={idx}
            class="text-base text-red-400 hover:text-red-300"
          >
            Remove
          </button>
        </div>
        <input type="hidden" name="when" value={format_when(rule[:when])} />
        <.live_component
          module={LoupeyWeb.ConditionBuilder}
          id={"output_condition_#{idx}"}
          value={format_when(rule[:when])}
          mode={:condition}
        />
        <div class="grid grid-cols-2 gap-2">
          <div>
            <label class="text-base text-gray-500">Background</label>
            <input type="color" name="background" value={rule[:background] || "#000000"}
              class="w-full h-7 bg-gray-700 border border-gray-600 rounded cursor-pointer"
            />
          </div>
          <div>
            <label class="text-base text-gray-500">LED Color</label>
            <input type="color" name="color" value={rule[:color] || "#ffffff"}
              class="w-full h-7 bg-gray-700 border border-gray-600 rounded cursor-pointer"
            />
          </div>
        </div>
        <div>
          <label class="text-base text-gray-500">Icon</label>
          <div class="flex gap-1">
            <input
              type="text"
              name="icon"
              value={rule[:icon] || ""}
              phx-debounce="300"
              placeholder="Click Browse to select"
              readonly
              class="flex-1 bg-gray-700 border border-gray-600 rounded px-1.5 py-1 text-base text-white truncate"
            />
            <button
              type="button"
              phx-click="toggle_icon_browser"
              phx-target={@myself}
              phx-value-idx={idx}
              class="text-base bg-gray-600 hover:bg-gray-500 text-white px-2 py-1 rounded whitespace-nowrap"
            >
              Browse
            </button>
            <button
              :if={rule[:icon] && rule[:icon] != ""}
              type="button"
              phx-click="clear_icon"
              phx-target={@myself}
              phx-value-idx={idx}
              class="text-base bg-gray-700 hover:bg-gray-600 text-red-400 px-1.5 py-1 rounded"
            >
              ✕
            </button>
          </div>
          <.icon_browser
            :if={@icon_browser_idx == idx}
            icon_files={@icon_files}
            rule={rule}
            idx={idx}
            myself={@myself}
          />
        </div>
        <div class="grid grid-cols-3 gap-2">
          <div>
            <label class="text-base text-gray-500">Fill amount</label>
            <input
              type="text"
              name="fill_amount"
              value={get_in(rule, [:fill, :amount]) || ""}
              phx-debounce="300"
              placeholder="50 or {{ expr }}"
              class="w-full bg-gray-700 border border-gray-600 rounded px-1.5 py-1 text-base text-white"
            />
          </div>
          <div>
            <label class="text-base text-gray-500">Direction</label>
            <select name="fill_direction"
              class="w-full bg-gray-700 border border-gray-600 rounded px-1.5 py-1 text-base text-white"
            >
              <option value="">None</option>
              <option :for={{label, val} <- @direction_options} value={val} selected={val == to_string(get_in(rule, [:fill, :direction]) || "")}>
                {label}
              </option>
            </select>
          </div>
          <div>
            <label class="text-base text-gray-500">Fill color</label>
            <input type="color" name="fill_color" value={get_in(rule, [:fill, :color]) || "#ffffff"}
              class="w-full h-7 bg-gray-700 border border-gray-600 rounded cursor-pointer"
            />
          </div>
        </div>
        <div class="grid grid-cols-4 gap-2">
          <div class="col-span-2">
            <label class="text-base text-gray-500">Text</label>
            <textarea
              name="text_content"
              rows="2"
              phx-debounce="300"
              placeholder="Text or use Insert below"
              class="w-full bg-gray-700 border border-gray-600 rounded px-1.5 py-1 text-base text-white font-mono resize-y"
            >{get_text_content(rule[:text]) || ""}</textarea>
            <.live_component
              module={LoupeyWeb.ConditionBuilder}
              id={"text_insert_#{idx}"}
              mode={:insert}
            />
          </div>
          <div>
            <label class="text-base text-gray-500">Text color</label>
            <input type="color" name="text_color" value={get_text_color(rule[:text])}
              class="w-full h-7 bg-gray-700 border border-gray-600 rounded cursor-pointer"
            />
          </div>
          <div>
            <label class="text-base text-gray-500">Align</label>
            <select name="text_valign"
              class="w-full bg-gray-700 border border-gray-600 rounded px-1.5 py-1 text-base text-white"
            >
              <option :for={{label, val} <- @valign_options} value={val} selected={val == to_string(get_text_valign(rule[:text]))}>
                {label}
              </option>
            </select>
          </div>
        </div>
      </form>
    </div>
    """
  end

  defp icon_browser(assigns) do
    ~H"""
    <div class="mt-1 bg-gray-900 border border-gray-600 rounded-lg p-2 max-h-52 overflow-y-auto">
      <div :if={@icon_files == []} class="text-base text-gray-500 p-2">No icons found</div>
      <div class="grid grid-cols-4 gap-1">
        <button
          :for={icon <- @icon_files}
          type="button"
          phx-click="pick_icon"
          phx-target={@myself}
          phx-value-path={icon.path}
          phx-value-idx={@idx}
          class={[
            "flex flex-col items-center p-1 rounded hover:bg-gray-700 transition",
            if(@rule[:icon] == icon.path, do: "bg-gray-700 ring-1 ring-blue-400", else: "")
          ]}
        >
          <img src={"/icons/#{icon.relative}"} class="w-10 h-10 object-contain" />
          <span class="text-base text-gray-400 truncate w-full text-center mt-0.5">{icon.name}</span>
        </button>
      </div>
    </div>
    """
  end

  defp save_delete_buttons(assigns) do
    ~H"""
    <div class="flex gap-2">
      <button
        phx-click="save_from_visual"
        phx-target={@myself}
        class="flex-1 bg-blue-600 hover:bg-blue-500 text-white text-base px-3 py-2 rounded-lg"
      >
        Save Binding
      </button>
      <button
        :if={@editing}
        phx-click="delete_binding"
        phx-target={@myself}
        data-confirm="Remove this binding?"
        class="bg-red-900 hover:bg-red-800 text-red-300 text-base px-3 py-2 rounded-lg"
      >
        Remove
      </button>
    </div>
    """
  end

  # -- Input rule events --

  @impl true
  def handle_event("add_input_rule", _params, socket) do
    form_data = socket.assigns.form_data
    default_trigger = socket.assigns[:control] |> trigger_options_for() |> hd() |> elem(1)

    new_rule = %{
      on: default_trigger,
      actions: [%{action: "call_service", domain: "", service: "", target: ""}]
    }

    form_data = %{form_data | input_rules: form_data.input_rules ++ [new_rule]}
    {:noreply, assign(socket, form_data: form_data)}
  end

  def handle_event("remove_input_rule", %{"idx" => idx}, socket) do
    form_data = socket.assigns.form_data
    rules = List.delete_at(form_data.input_rules, String.to_integer(idx))
    {:noreply, assign(socket, form_data: %{form_data | input_rules: rules})}
  end

  def handle_event("update_input_rule_form", params, socket) do
    idx = String.to_integer(params["idx"])
    form_data = socket.assigns.form_data

    rules =
      List.update_at(form_data.input_rules, idx, fn rule ->
        rule
        |> Map.put(:on, params["on"] || rule[:on])
        |> Map.put(:when, params["when"])
      end)

    {:noreply, assign(socket, form_data: %{form_data | input_rules: rules})}
  end

  def handle_event("add_action", %{"rule-idx" => idx_str}, socket) do
    idx = String.to_integer(idx_str)
    form_data = socket.assigns.form_data
    new_action = %{action: "call_service", domain: "", service: "", target: ""}

    rules =
      List.update_at(form_data.input_rules, idx, fn rule ->
        Map.update(rule, :actions, [new_action], &(&1 ++ [new_action]))
      end)

    {:noreply, assign(socket, form_data: %{form_data | input_rules: rules})}
  end

  def handle_event("remove_action", %{"rule-idx" => ridx, "action-idx" => aidx}, socket) do
    ridx = String.to_integer(ridx)
    aidx = String.to_integer(aidx)
    form_data = socket.assigns.form_data

    rules =
      List.update_at(form_data.input_rules, ridx, fn rule ->
        Map.update(rule, :actions, [], &List.delete_at(&1, aidx))
      end)

    {:noreply, assign(socket, form_data: %{form_data | input_rules: rules})}
  end

  def handle_event("update_action_form", params, socket) do
    ridx = String.to_integer(params["rule_idx"])
    aidx = String.to_integer(params["action_idx"])
    form_data = socket.assigns.form_data

    rules =
      List.update_at(form_data.input_rules, ridx, fn rule ->
        actions =
          List.update_at(rule.actions, aidx, fn action ->
            action
            |> Map.put(:action, presence(params["action_type"]) || action[:action])
            |> Map.put(:domain, presence(params["domain"]) || action[:domain])
            |> Map.put(:service, presence(params["service"]) || action[:service])
            |> Map.put(:target, presence(params["target"]) || action[:target])
            |> Map.put(:layout, presence(params["layout"]) || action[:layout])
            |> update_action_service_data(params["service_data"])
          end)

        %{rule | actions: actions}
      end)

    {:noreply, assign(socket, form_data: %{form_data | input_rules: rules})}
  end

  # -- Output rule events --

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

  # -- Icon events --

  def handle_event("toggle_icon_browser", %{"idx" => idx_str}, socket) do
    idx = String.to_integer(idx_str)

    if socket.assigns.icon_browser_idx == idx do
      {:noreply, assign(socket, icon_browser_idx: nil)}
    else
      icon_files = Loupey.Icons.scan()
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

  # -- Persistence events --

  def handle_event("save_from_visual", _params, socket) do
    yaml = FormCodec.encode(socket.assigns.form_data, socket.assigns[:entity_id])
    send(self(), {:save_binding_yaml, yaml})
    {:noreply, socket}
  end

  def handle_event("delete_binding", _params, socket) do
    send(self(), :delete_binding)
    {:noreply, socket}
  end

  # -- Form update helpers --

  defp update_action_service_data(action, nil), do: action

  defp update_action_service_data(action, sd),
    do: Map.put(action, :service_data, parse_service_data(sd))

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
    has_fill = presence(params["fill_amount"]) || presence(params["fill_direction"])

    fill =
      if has_fill do
        %{}
        |> put_if_not_empty(:amount, params["fill_amount"])
        |> put_if_not_empty(:direction, params["fill_direction"])
        |> put_if_not_empty(:color, params["fill_color"])
      else
        %{}
      end

    if fill == %{}, do: Map.delete(rule, :fill), else: Map.put(rule, :fill, fill)
  end

  defp update_text(rule, params) do
    has_content = presence(params["text_content"])

    text =
      if has_content do
        %{content: has_content}
        |> put_if_not_empty(:valign, params["text_valign"])
        |> put_if_not_empty(:color, params["text_color"])
      else
        %{}
      end

    if text == %{}, do: Map.delete(rule, :text), else: Map.put(rule, :text, text)
  end

  defp presence(nil), do: nil
  defp presence(""), do: nil
  defp presence(value), do: value

  defp put_if_not_empty(map, _key, nil), do: map
  defp put_if_not_empty(map, _key, ""), do: map
  defp put_if_not_empty(map, key, value), do: Map.put(map, key, value)

  defp put_if_present(rule, _key, nil), do: rule
  defp put_if_present(rule, _key, ""), do: rule
  defp put_if_present(rule, key, value), do: Map.put(rule, key, value)

  defp parse_when_value(nil), do: nil
  defp parse_when_value("true"), do: true
  defp parse_when_value(""), do: true
  defp parse_when_value(expr), do: expr

  # -- Template helpers --

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

  # -- Update lifecycle helpers --

  defp assign_ha_services(socket) do
    services = Loupey.HA.get_services()

    # Derive domains from all known entities, not just service domains,
    # so that domains like sensor/binary_sensor appear in the dropdown.
    entity_domains =
      Loupey.HA.get_all_states()
      |> Enum.map(fn s -> s.entity_id |> String.split(".", parts: 2) |> hd() end)
      |> Enum.uniq()

    domains = Enum.sort(Enum.uniq(Map.keys(services) ++ entity_domains))

    socket
    |> assign(:ha_services, services)
    |> assign(:ha_domains, domains)
  end

  defp apply_action_target(form_data, indices_str, entity_id) do
    case String.split(indices_str, "_") do
      [ridx_str, aidx_str] ->
        ridx = String.to_integer(ridx_str)
        aidx = String.to_integer(aidx_str)
        domain = entity_id |> String.split(".") |> hd()

        rules =
          List.update_at(form_data.input_rules, ridx, fn rule ->
            actions =
              List.update_at(rule.actions, aidx, &set_action_target(&1, entity_id, domain))

            %{rule | actions: actions}
          end)

        %{form_data | input_rules: rules}

      _ ->
        form_data
    end
  end

  defp trigger_options_for(nil), do: @trigger_options

  defp trigger_options_for(control) do
    caps = control.capabilities

    []
    |> add_if(MapSet.member?(caps, :press), [{"Press", "press"}, {"Release", "release"}])
    |> add_if(MapSet.member?(caps, :rotate), [
      {"Rotate CW", "rotate_cw"},
      {"Rotate CCW", "rotate_ccw"}
    ])
    |> add_if(MapSet.member?(caps, :touch), [
      {"Touch Start", "touch_start"},
      {"Touch Move", "touch_move"},
      {"Touch End", "touch_end"}
    ])
  end

  defp add_if(list, true, items), do: list ++ items
  defp add_if(list, false, _items), do: list

  defp apply_condition_update(form_data, idx_str, expr) do
    idx = String.to_integer(idx_str)

    rules =
      List.update_at(form_data.output_rules, idx, fn rule ->
        Map.put(rule, :when, expr)
      end)

    %{form_data | output_rules: rules}
  end

  defp apply_text_insert(form_data, idx_str, expr) do
    idx = String.to_integer(idx_str)

    rules =
      List.update_at(form_data.output_rules, idx, fn rule ->
        text = rule[:text] || %{}
        existing = text[:content] || ""
        updated = if existing == "", do: expr, else: existing <> expr
        Map.put(rule, :text, Map.put(text, :content, updated))
      end)

    %{form_data | output_rules: rules}
  end

  defp resolve_form_data(assigns, socket, first_mount, yaml_changed, new_yaml) do
    current = socket.assigns[:form_data] || FormCodec.decode(new_yaml)

    case apply_parent_update(assigns, current) do
      {:ok, form_data} -> form_data
      :none when first_mount or yaml_changed -> FormCodec.decode(new_yaml)
      :none -> socket.assigns.form_data
    end
  end

  defp apply_parent_update(%{action_target_selected: {indices, entity_id}}, form_data) do
    {:ok, apply_action_target(form_data, indices, entity_id)}
  end

  defp apply_parent_update(%{condition_update: {idx_str, expr}}, form_data) do
    {:ok, apply_condition_update(form_data, idx_str, expr)}
  end

  defp apply_parent_update(%{text_insert: {idx_str, expr}}, form_data) do
    {:ok, apply_text_insert(form_data, idx_str, expr)}
  end

  defp apply_parent_update(_assigns, _form_data), do: :none

  defp set_action_target(action, entity_id, domain) do
    action = Map.put(action, :target, entity_id)
    if (action[:domain] || "") == "", do: Map.put(action, :domain, domain), else: action
  end

  defp services_for_domain("", _services), do: []
  defp services_for_domain(nil, _services), do: []
  defp services_for_domain(domain, services), do: Map.get(services, domain, [])

  defp format_service_data(nil), do: ""
  defp format_service_data(data) when data == %{}, do: ""

  defp format_service_data(data) when is_map(data) do
    Enum.map_join(data, "\n", fn {k, v} -> "#{k}: #{format_sd_value(v)}" end)
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
end
