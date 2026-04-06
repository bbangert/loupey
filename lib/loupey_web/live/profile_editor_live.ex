defmodule LoupeyWeb.ProfileEditorLive do
  use LoupeyWeb, :live_view

  alias Loupey.Driver.Loupedeck, as: LoupedeckDriver
  alias Loupey.Profiles
  alias Loupey.Schemas.Binding

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    profile = Profiles.get_profile(String.to_integer(id))

    if profile do
      # Get device spec for visual layout
      spec = get_device_spec(profile.device_type)
      layouts = profile.layouts |> Enum.sort_by(& &1.position)
      active_layout = List.first(layouts)

      {:ok,
       assign(socket,
         profile: profile,
         spec: spec,
         layouts: layouts,
         active_layout: active_layout,
         active_bindings: layout_bindings(active_layout),
         selected_control: nil,
         editing_binding: nil,
         show_new_layout: false,
         entity_search: "",
         entity_matches: [],
         show_entity_dropdown: false,
         binding_yaml: "",
         editor_mode: :visual
       )}
    else
      {:ok,
       socket
       |> put_flash(:error, "Profile not found")
       |> redirect(to: ~p"/profiles")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <div class="flex items-center gap-4 mb-6">
        <a href={~p"/profiles"} class="text-gray-400 hover:text-white">&larr; Back</a>
        <h1 class="text-2xl font-bold">{@profile.name}</h1>
        <span class="text-sm text-gray-400">{@profile.device_type}</span>
      </div>

      <div class="grid grid-cols-1 lg:grid-cols-3 gap-6">
        <%!-- Left: Layout manager + Device grid --%>
        <div class="lg:col-span-2 space-y-6">
          <%!-- Layout tabs --%>
          <div class="bg-gray-800 rounded-lg p-4 border border-gray-700">
            <div class="flex items-center gap-2 mb-3">
              <h2 class="text-sm font-semibold text-gray-400 uppercase tracking-wide">Layouts</h2>
              <button
                phx-click="toggle_new_layout"
                class="text-xs bg-gray-700 hover:bg-gray-600 text-white px-2 py-1 rounded"
              >
                + Add
              </button>
            </div>

            <%!-- New layout form --%>
            <div :if={@show_new_layout} class="mb-3">
              <form phx-submit="create_layout" class="flex gap-2">
                <input
                  type="text"
                  name="name"
                  placeholder="Layout name"
                  autofocus
                  class="bg-gray-700 border border-gray-600 rounded px-2 py-1 text-sm text-white flex-1"
                />
                <button type="submit" class="bg-blue-600 hover:bg-blue-500 text-white text-xs px-3 py-1 rounded">
                  Create
                </button>
                <button type="button" phx-click="toggle_new_layout" class="text-xs text-gray-400 hover:text-white">
                  Cancel
                </button>
              </form>
            </div>

            <%!-- Layout tabs row --%>
            <div class="flex flex-wrap gap-1">
              <button
                :for={layout <- @layouts}
                phx-click="select_layout"
                phx-value-id={layout.id}
                class={[
                  "text-sm px-3 py-1.5 rounded-lg transition",
                  if(@active_layout && @active_layout.id == layout.id,
                    do: "bg-blue-600 text-white",
                    else: "bg-gray-700 text-gray-300 hover:bg-gray-600"
                  )
                ]}
              >
                {layout.name}
              </button>
            </div>
          </div>

          <%!-- Device grid --%>
          <div class="bg-gray-800 rounded-lg p-6 border border-gray-700">
            <h2 class="text-sm font-semibold text-gray-400 uppercase tracking-wide mb-4">
              Device Layout
              <span :if={@active_layout} class="text-blue-400 normal-case">
                — {if @active_layout, do: @active_layout.name, else: "Select a layout"}
              </span>
            </h2>

            <div :if={@spec && @active_layout} id={"grid-#{@active_layout.id}"}>
              <.device_grid
                spec={@spec}
                bindings={@active_bindings}
                selected={@selected_control}
              />
            </div>

            <div :if={!@active_layout} class="text-center text-gray-500 py-8">
              Create a layout first to configure controls.
            </div>
          </div>
        </div>

        <%!-- Right: Binding editor --%>
        <div class="space-y-6">
          <div class="bg-gray-800 rounded-lg p-4 border border-gray-700">
            <h2 class="text-sm font-semibold text-gray-400 uppercase tracking-wide mb-3">
              Binding Editor
            </h2>

            <div :if={!@selected_control} class="text-center text-gray-500 py-8 text-sm">
              Click a control on the device grid to edit its binding.
            </div>

            <div :if={@selected_control}>
              <div class="mb-3">
                <span class="text-xs text-gray-400">Control:</span>
                <span class="text-sm text-white ml-1 font-mono">{format_control_id(@selected_control)}</span>
              </div>

              <%!-- Entity browser toggle --%>
              <div class="mb-3 relative">
                <label class="block text-xs text-gray-400 mb-1">Entity ID</label>
                <input
                  type="text"
                  phx-keyup="entity_search"
                  phx-blur="entity_blur"
                  phx-focus="entity_focus"
                  phx-debounce="100"
                  value={@entity_search}
                  placeholder="Start typing... e.g. light."
                  autocomplete="off"
                  class="w-full bg-gray-700 border border-gray-600 rounded px-2 py-1 text-sm text-white"
                />
                <.entity_autocomplete
                  :if={@entity_matches != [] and @show_entity_dropdown}
                  matches={@entity_matches}
                />
              </div>

              <%!-- Editor mode tabs --%>
              <div class="flex gap-1 mt-3 mb-2">
                <button
                  phx-click="set_editor_mode"
                  phx-value-mode="visual"
                  class={[
                    "text-xs px-3 py-1 rounded-t",
                    if(@editor_mode == :visual, do: "bg-gray-900 text-white", else: "bg-gray-700 text-gray-400")
                  ]}
                >
                  Visual
                </button>
                <button
                  phx-click="set_editor_mode"
                  phx-value-mode="yaml"
                  class={[
                    "text-xs px-3 py-1 rounded-t",
                    if(@editor_mode == :yaml, do: "bg-gray-900 text-white", else: "bg-gray-700 text-gray-400")
                  ]}
                >
                  YAML
                </button>
              </div>

              <%!-- Visual configurator --%>
              <div :if={@editor_mode == :visual} class="bg-gray-900 rounded-b rounded-tr p-3 border border-gray-700">
                <.live_component
                  module={LoupeyWeb.BindingFormComponent}
                  id="binding_form"
                  yaml={@binding_yaml}
                  entity_id={@entity_search}
                  editing={@editing_binding != nil and @editing_binding.id != nil}
                />
              </div>

              <%!-- YAML editor --%>
              <div :if={@editor_mode == :yaml}>
                <form phx-submit="save_binding">
                  <textarea
                    name="yaml"
                    rows="18"
                    phx-debounce="500"
                    class="w-full bg-gray-900 border border-gray-600 rounded-b rounded-tr px-3 py-2 text-xs text-green-300 font-mono leading-relaxed"
                  >{@binding_yaml}</textarea>
                  <div class="flex gap-2 mt-2">
                    <button
                      type="submit"
                      class="bg-blue-600 hover:bg-blue-500 text-white text-xs px-3 py-1.5 rounded"
                    >
                      Save Binding
                    </button>
                    <button
                      :if={@editing_binding && @editing_binding.id}
                      type="button"
                      phx-click="delete_binding"
                      data-confirm="Remove this binding?"
                      class="bg-red-900 hover:bg-red-800 text-red-300 text-xs px-3 py-1.5 rounded"
                    >
                      Remove
                    </button>
                  </div>
                </form>
              </div>
            </div>
          </div>

          <%!-- Layout actions --%>
          <div :if={@active_layout} class="bg-gray-800 rounded-lg p-4 border border-gray-700">
            <h2 class="text-sm font-semibold text-gray-400 uppercase tracking-wide mb-3">Layout Actions</h2>
            <div class="space-y-2">
              <button
                phx-click="set_active_layout"
                class="w-full text-sm bg-green-800 hover:bg-green-700 text-white px-3 py-2 rounded-lg text-left"
              >
                Set as default layout
              </button>
              <button
                phx-click="delete_layout"
                phx-value-id={@active_layout.id}
                data-confirm="Delete this layout and all its bindings?"
                class="w-full text-sm bg-red-900 hover:bg-red-800 text-red-300 px-3 py-2 rounded-lg text-left"
              >
                Delete layout
              </button>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # -- Device grid component --

  defp device_grid(assigns) do
    controls = assigns.spec.controls
    bindings = assigns.bindings
    selected = assigns.selected

    # Group controls by type for visual layout
    keys = Enum.filter(controls, &key_control?/1) |> Enum.sort_by(&elem(&1.id, 1))
    knobs = Enum.filter(controls, &knob_control?/1)
    buttons = Enum.filter(controls, &button_control?/1) |> Enum.sort_by(&elem(&1.id, 1))
    strips = Enum.filter(controls, &strip_control?/1)

    assigns =
      assigns
      |> Map.put(:keys, keys)
      |> Map.put(:knobs, knobs)
      |> Map.put(:buttons, buttons)
      |> Map.put(:strips, strips)
      |> Map.put(:bindings, bindings)
      |> Map.put(:selected, selected)

    # Use pixel dimensions from the spec to calculate proportional sizes.
    # Scale factor: 1 device pixel = 0.5 CSS pixels (so 90px key → 45px on screen)
    scale = 1

    key_size = if keys != [], do: hd(keys).display.width, else: 90
    cols = length(keys) |> div(3) |> max(1)

    assigns =
      assigns
      |> Map.put(:scale, scale)
      |> Map.put(:key_px, round(key_size * scale))
      |> Map.put(:cols, cols)

    ~H"""
    <div class="space-y-4">
      <%!-- Main display area: strips + key grid --%>
      <div class="flex gap-1 items-start">
        <%!-- Left strip --%>
        <div :for={strip <- Enum.filter(@strips, &(&1.id == :left_strip))}>
          <.control_cell
            control={strip}
            bindings={@bindings}
            selected={@selected}
            style={"width: #{round(strip.display.width * @scale)}px; height: #{round(strip.display.height * @scale)}px"}
          />
        </div>

        <%!-- Key grid --%>
        <div class="grid gap-1" style={"grid-template-columns: repeat(#{@cols}, #{@key_px}px)"}>
          <.control_cell
            :for={key <- @keys}
            control={key}
            bindings={@bindings}
            selected={@selected}
            style={"width: #{@key_px}px; height: #{@key_px}px"}
          />
        </div>

        <%!-- Right strip --%>
        <div :for={strip <- Enum.filter(@strips, &(&1.id == :right_strip))}>
          <.control_cell
            control={strip}
            bindings={@bindings}
            selected={@selected}
            style={"width: #{round(strip.display.width * @scale)}px; height: #{round(strip.display.height * @scale)}px"}
          />
        </div>
      </div>

      <%!-- Buttons row --%>
      <div class="flex gap-1">
        <.control_cell
          :for={btn <- @buttons}
          control={btn}
          bindings={@bindings}
          selected={@selected}
          style={"width: #{round(@key_px * 0.6)}px; height: #{round(@key_px * 0.4)}px"}
        />
      </div>

      <%!-- Knobs row --%>
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

  defp entity_autocomplete(assigns) do
    ~H"""
    <div class="absolute z-10 w-full mt-1 bg-gray-900 border border-gray-600 rounded-lg max-h-48 overflow-y-auto shadow-lg">
      <button
        :for={id <- @matches}
        phx-click="pick_entity"
        phx-value-entity={id}
        class="block w-full text-left text-xs text-gray-300 hover:text-white hover:bg-gray-700 px-2 py-1 truncate"
      >
        {id}
      </button>
    </div>
    """
  end

  # -- Events --

  @impl true
  def handle_event("toggle_new_layout", _params, socket) do
    {:noreply, assign(socket, show_new_layout: !socket.assigns.show_new_layout)}
  end

  def handle_event("create_layout", %{"name" => name}, socket) do
    profile = socket.assigns.profile
    position = length(socket.assigns.layouts)

    case Profiles.create_layout(%{"name" => name, "profile_id" => profile.id, "position" => position}) do
      {:ok, _layout} ->
        {:noreply, reload_profile(socket, :show_new_layout, false)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to create layout")}
    end
  end

  def handle_event("select_layout", %{"id" => id}, socket) do
    layout_id = String.to_integer(id)

    # Reload profile from DB to get fresh bindings
    profile = Profiles.get_profile(socket.assigns.profile.id)
    layouts = profile.layouts |> Enum.sort_by(& &1.position)
    layout = Enum.find(layouts, &(&1.id == layout_id))

    # If profile is active, switch the device to show this layout
    if layout && profile.active do
      Profiles.update_profile(profile, %{"active_layout" => layout.name})
      Loupey.Orchestrator.reload_active_profile()
    end

    bindings = layout_bindings(layout)

    {:noreply,
     assign(socket,
       profile: profile,
       layouts: layouts,
       active_layout: layout,
       active_bindings: bindings,
       selected_control: nil,
       editing_binding: nil,
       binding_yaml: ""
     )}
  end

  def handle_event("delete_layout", %{"id" => id}, socket) do
    layout = Enum.find(socket.assigns.layouts, &(&1.id == String.to_integer(id)))
    if layout, do: Profiles.delete_layout(layout)
    {:noreply, reload_profile(socket)}
  end

  def handle_event("set_active_layout", _params, socket) do
    if socket.assigns.active_layout do
      Profiles.update_profile(socket.assigns.profile, %{
        "active_layout" => socket.assigns.active_layout.name
      })
    end

    {:noreply,
     socket
     |> reload_profile()
     |> put_flash(:info, "Default layout set")}
  end

  def handle_event("select_control", %{"control" => control_id_str}, socket) do
    layout = socket.assigns.active_layout

    if layout do
      # Find existing binding for this control in the active layout
      existing =
        Enum.find(layout.bindings, fn b -> b.control_id == control_id_str end)

      yaml =
        if existing do
          existing.yaml
        else
          default_yaml(control_id_str)
        end

      entity_id = (existing && existing.entity_id) || ""

      {:noreply,
       assign(socket,
         selected_control: parse_control_id(control_id_str),
         editing_binding: existing,
         binding_yaml: yaml,
         entity_search: entity_id,
         entity_matches: [],
         show_entity_dropdown: false
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_event("entity_search", %{"value" => query}, socket) do
    matches =
      if String.length(query) >= 1 do
        search_entities(query)
      else
        []
      end

    {:noreply, assign(socket, entity_search: query, entity_matches: matches, show_entity_dropdown: matches != [])}
  end

  def handle_event("entity_focus", _params, socket) do
    matches =
      if String.length(socket.assigns.entity_search) >= 1 do
        search_entities(socket.assigns.entity_search)
      else
        []
      end

    {:noreply, assign(socket, show_entity_dropdown: matches != [], entity_matches: matches)}
  end

  def handle_event("entity_blur", _params, socket) do
    # Small delay to allow click on dropdown item to register before hiding
    Process.send_after(self(), :hide_entity_dropdown, 200)
    {:noreply, socket}
  end

  def handle_event("pick_entity", %{"entity" => entity_id}, socket) do
    yaml = update_yaml_entity(socket.assigns.binding_yaml, entity_id)

    {:noreply,
     assign(socket,
       entity_search: entity_id,
       entity_matches: [],
       show_entity_dropdown: false,
       binding_yaml: yaml
     )}
  end

  def handle_event("save_binding", %{"yaml" => yaml}, socket) do
    {:noreply, elem(do_save_binding(yaml, socket), 1)}
  end

  defp do_save_binding(yaml, socket) do
    layout = socket.assigns.active_layout
    control_id_str = format_control_id(socket.assigns.selected_control)
    entity_id = extract_entity_id(yaml)

    case socket.assigns.editing_binding do
      %Binding{id: id} when not is_nil(id) ->
        binding = Enum.find(layout.bindings, &(&1.id == id))

        case Profiles.update_binding(binding, %{"yaml" => yaml, "entity_id" => entity_id}) do
          {:ok, _} ->
            Loupey.Orchestrator.reload_active_profile()

            {:ok,
             socket
             |> assign(binding_yaml: yaml)
             |> reload_profile()
             |> put_flash(:info, "Binding saved")}

          {:error, _} ->
            {:error, put_flash(socket, :error, "Failed to save binding")}
        end

      _ ->
        case Profiles.create_binding(%{
               "layout_id" => layout.id,
               "control_id" => control_id_str,
               "entity_id" => entity_id,
               "yaml" => yaml
             }) do
          {:ok, _} ->
            Loupey.Orchestrator.reload_active_profile()

            {:ok,
             socket
             |> assign(binding_yaml: yaml)
             |> reload_profile()
             |> put_flash(:info, "Binding saved")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to create binding")}
        end
    end
  end

  def handle_event("set_editor_mode", %{"mode" => mode}, socket) do
    {:noreply, assign(socket, editor_mode: String.to_atom(mode))}
  end

  def handle_event("delete_binding", _params, socket) do
    if socket.assigns.editing_binding do
      Profiles.delete_binding(socket.assigns.editing_binding)
    end

    {:noreply,
     socket
     |> reload_profile()
     |> assign(editing_binding: nil, binding_yaml: "", selected_control: nil)}
  end

  @impl true
  def handle_info(:hide_entity_dropdown, socket) do
    {:noreply, assign(socket, show_entity_dropdown: false)}
  end

  def handle_info({:update_yaml, yaml}, socket) do
    {:noreply, assign(socket, binding_yaml: yaml, editor_mode: :yaml)}
  end

  def handle_info({:save_binding_yaml, yaml}, socket) do
    # Reuse the save_binding logic with the generated YAML
    socket = assign(socket, binding_yaml: yaml)
    {:noreply, elem(do_save_binding(yaml, socket), 1)}
  end

  def handle_info(:delete_binding, socket) do
    if socket.assigns.editing_binding do
      Profiles.delete_binding(socket.assigns.editing_binding)
      Loupey.Orchestrator.reload_active_profile()
    end

    {:noreply,
     socket
     |> reload_profile()
     |> assign(editing_binding: nil, binding_yaml: "", selected_control: nil)
     |> put_flash(:info, "Binding removed")}
  end

  # -- Helpers --

  defp search_entities(query) do
    Loupey.HA.get_all_states()
    |> Enum.map(& &1.entity_id)
    |> Enum.filter(&String.contains?(&1, query))
    |> Enum.sort()
    |> Enum.take(20)
  rescue
    _ -> []
  end

  defp update_yaml_entity(yaml, entity_id) do
    if String.contains?(yaml, "entity_id:") do
      Regex.replace(~r/entity_id:.*/, yaml, "entity_id: \"#{entity_id}\"")
    else
      "entity_id: \"#{entity_id}\"\n" <> yaml
    end
  end

  defp reload_profile(socket, extra_key \\ nil, extra_val \\ nil) do
    profile = Profiles.get_profile(socket.assigns.profile.id)
    layouts = profile.layouts |> Enum.sort_by(& &1.position)

    active_layout =
      if socket.assigns.active_layout do
        Enum.find(layouts, &(&1.id == socket.assigns.active_layout.id)) || List.first(layouts)
      else
        List.first(layouts)
      end

    # Re-select binding if a control was selected
    {editing_binding, binding_yaml} =
      if socket.assigns.selected_control && active_layout do
        control_id_str = format_control_id(socket.assigns.selected_control)
        existing = Enum.find(active_layout.bindings, &(&1.control_id == control_id_str))
        {existing, (existing && existing.yaml) || socket.assigns.binding_yaml}
      else
        {nil, ""}
      end

    socket = assign(socket,
      profile: profile,
      layouts: layouts,
      active_layout: active_layout,
      active_bindings: layout_bindings(active_layout),
      editing_binding: editing_binding,
      binding_yaml: binding_yaml
    )

    if extra_key, do: assign(socket, [{extra_key, extra_val}]), else: socket
  end

  defp get_device_spec(device_type) do
    # Try to find a connected device matching this type
    case Loupey.Devices.discover() do
      [{driver, _tty} | _] ->
        spec = driver.device_spec()
        if spec.type == device_type, do: spec, else: spec

      [] ->
        # Fallback to Loupedeck Live spec
        LoupedeckDriver.device_spec()
    end
  end

  defp layout_bindings(nil), do: %{}

  defp layout_bindings(layout) do
    Map.new(layout.bindings, fn b -> {b.control_id, b} end)
  end

  defp key_control?(%{id: {:key, _}, display: %{width: w, height: h}}) when w == h, do: true
  defp key_control?(_), do: false

  defp knob_control?(%{capabilities: caps}), do: MapSet.member?(caps, :rotate)
  defp knob_control?(_), do: false

  defp button_control?(%{id: {:button, _}}), do: true
  defp button_control?(_), do: false

  defp strip_control?(%{id: id}) when id in [:left_strip, :right_strip], do: true
  defp strip_control?(_), do: false

  defp format_control_id({type, num}), do: "{:#{type}, #{num}}"
  defp format_control_id(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp format_control_id(other), do: inspect(other)

  defp parse_control_id(str) do
    case Regex.run(~r/^\{:(\w+), (\d+)\}$/, str) do
      [_, type, num] -> {String.to_atom(type), String.to_integer(num)}
      _ -> String.to_atom(str)
    end
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

  defp extract_entity_id(yaml) do
    case Regex.run(~r/entity_id:\s*"?([^"\n]+)"?/, yaml) do
      [_, id] -> String.trim(id)
      _ -> nil
    end
  end

  defp default_yaml(_control_id) do
    """
    input_rules: []
    output_rules:
      - when: true
        background: "#111111"
    """
  end
end
