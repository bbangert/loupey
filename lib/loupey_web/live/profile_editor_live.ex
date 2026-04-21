defmodule LoupeyWeb.ProfileEditorLive do
  @moduledoc """
  LiveView for editing a device profile.

  Coordinates between the device grid, layout manager, blueprint picker,
  and binding editor components. Holds the profile/layout state and
  routes messages between components and the database.
  """
  use LoupeyWeb, :live_view

  alias Loupey.Profiles
  alias Loupey.Schemas.Binding
  alias LoupeyWeb.DeviceGrid

  import DeviceGrid, only: [format_control_id: 1, parse_control_id: 1]

  # -- Mount --

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    profile = Profiles.get_profile(String.to_integer(id))

    case {profile, profile && get_device_spec(profile.device_type)} do
      {nil, _} ->
        {:ok,
         socket
         |> put_flash(:error, "Profile not found")
         |> redirect(to: ~p"/profiles")}

      {profile, nil} ->
        {:ok,
         socket
         |> put_flash(:error, "No driver registered for device type \"#{profile.device_type}\"")
         |> redirect(to: ~p"/profiles")}

      {profile, spec} ->
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
           binding_yaml: "",
           editor_mode: :visual
         )}
    end
  end

  # -- Render --

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
          <.layout_manager
            layouts={@layouts}
            active_layout={@active_layout}
            show_new_layout={@show_new_layout}
          />

          <div class="bg-gray-800 rounded-lg p-6 border border-gray-700">
            <h2 class="text-sm font-semibold text-gray-400 uppercase tracking-wide mb-4">
              Device Layout
              <span :if={@active_layout} class="text-blue-400 normal-case">
                — {@active_layout.name}
              </span>
            </h2>

            <div :if={@spec && @active_layout} id={"grid-#{@active_layout.id}"}>
              <DeviceGrid.grid
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

              <%!-- Blueprint picker --%>
              <div class="mb-3">
                <.live_component
                  module={LoupeyWeb.BlueprintPicker}
                  id="blueprint_picker"
                  entity_search={@entity_search}
                />
              </div>

              <%!-- Editor mode tabs --%>
              <.editor_tabs mode={@editor_mode} />

              <%!-- Visual configurator --%>
              <div :if={@editor_mode == :visual} class="bg-gray-900 rounded-b rounded-tr p-3 border border-gray-700">
                <.live_component
                  module={LoupeyWeb.BindingFormComponent}
                  id="binding_form"
                  yaml={@binding_yaml}
                  entity_id={@entity_search}
                  editing={@editing_binding != nil and @editing_binding.id != nil}
                  control={@selected_control && Loupey.Device.Spec.find_control(@spec, @selected_control)}
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
                    <button type="submit" class="bg-blue-600 hover:bg-blue-500 text-white text-xs px-3 py-1.5 rounded">
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

  # -- Function components --

  defp layout_manager(assigns) do
    ~H"""
    <div class="bg-gray-800 rounded-lg p-4 border border-gray-700">
      <div class="flex items-center gap-2 mb-3">
        <h2 class="text-sm font-semibold text-gray-400 uppercase tracking-wide">Layouts</h2>
        <button phx-click="toggle_new_layout" class="text-xs bg-gray-700 hover:bg-gray-600 text-white px-2 py-1 rounded">
          + Add
        </button>
      </div>

      <div :if={@show_new_layout} class="mb-3">
        <form phx-submit="create_layout" class="flex gap-2">
          <input
            type="text" name="name" placeholder="Layout name" autofocus
            class="bg-gray-700 border border-gray-600 rounded px-2 py-1 text-sm text-white flex-1"
          />
          <button type="submit" class="bg-blue-600 hover:bg-blue-500 text-white text-xs px-3 py-1 rounded">Create</button>
          <button type="button" phx-click="toggle_new_layout" class="text-xs text-gray-400 hover:text-white">Cancel</button>
        </form>
      </div>

      <div class="flex flex-wrap gap-1">
        <button
          :for={layout <- @layouts}
          phx-click="select_layout"
          phx-value-id={layout.id}
          class={[
            "text-sm px-3 py-1.5 rounded-lg transition",
            if(@active_layout && @active_layout.id == layout.id,
              do: "bg-blue-600 text-white",
              else: "bg-gray-700 text-gray-300 hover:bg-gray-600")
          ]}
        >
          {layout.name}
        </button>
      </div>
    </div>
    """
  end

  defp editor_tabs(assigns) do
    ~H"""
    <div class="flex gap-1 mt-3 mb-2">
      <button
        :for={mode <- [:visual, :yaml]}
        phx-click="set_editor_mode"
        phx-value-mode={mode}
        class={[
          "text-xs px-3 py-1 rounded-t capitalize",
          if(@mode == mode, do: "bg-gray-900 text-white", else: "bg-gray-700 text-gray-400")
        ]}
      >
        {mode}
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
    position = length(socket.assigns.layouts)

    case Profiles.create_layout(%{
           "name" => name,
           "profile_id" => socket.assigns.profile.id,
           "position" => position
         }) do
      {:ok, _} -> {:noreply, reload_profile(socket, :show_new_layout, false)}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Failed to create layout")}
    end
  end

  def handle_event("select_layout", %{"id" => id}, socket) do
    layout_id = String.to_integer(id)
    profile = Profiles.get_profile(socket.assigns.profile.id)
    layouts = profile.layouts |> Enum.sort_by(& &1.position)
    layout = Enum.find(layouts, &(&1.id == layout_id))

    if layout && profile.active do
      Profiles.update_profile(profile, %{"active_layout" => layout.name})
      Loupey.Orchestrator.reload_active_profile()
    end

    {:noreply,
     assign(socket,
       profile: profile,
       layouts: layouts,
       active_layout: layout,
       active_bindings: layout_bindings(layout),
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

    {:noreply, socket |> reload_profile() |> put_flash(:info, "Default layout set")}
  end

  def handle_event("select_control", %{"control" => control_id_str}, socket) do
    layout = socket.assigns.active_layout

    if layout do
      existing = Enum.find(layout.bindings, &(&1.control_id == control_id_str))
      yaml = if existing, do: existing.yaml, else: default_yaml()
      entity_id = (existing && existing.entity_id) || ""

      {:noreply,
       assign(socket,
         selected_control: parse_control_id(control_id_str),
         editing_binding: existing,
         binding_yaml: yaml,
         entity_search: entity_id
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_event("save_binding", %{"yaml" => yaml}, socket) do
    {:noreply, elem(do_save_binding(yaml, socket), 1)}
  end

  def handle_event("set_editor_mode", %{"mode" => mode}, socket) when mode in ~w(visual yaml) do
    {:noreply, assign(socket, editor_mode: String.to_existing_atom(mode))}
  end

  def handle_event("set_editor_mode", _params, socket), do: {:noreply, socket}

  def handle_event("delete_binding", _params, socket) do
    if socket.assigns.editing_binding do
      Profiles.delete_binding(socket.assigns.editing_binding)
      Loupey.Orchestrator.reload_active_profile()
    end

    {:noreply,
     socket
     |> reload_profile()
     |> assign(editing_binding: nil, binding_yaml: "", selected_control: nil)}
  end

  # -- Messages from child components --

  @impl true
  def handle_info({:entity_selected, "binding_entity", entity_id}, socket) do
    yaml = update_yaml_entity(socket.assigns.binding_yaml, entity_id)
    {:noreply, assign(socket, entity_search: entity_id, binding_yaml: yaml)}
  end

  def handle_info({:entity_selected, "bp_entity_" <> _name, entity_id}, socket) do
    {:noreply, assign(socket, entity_search: entity_id)}
  end

  def handle_info({:entity_selected, "action_target_" <> indices, entity_id}, socket) do
    # Forward to the binding form component via a message
    send_update(LoupeyWeb.BindingFormComponent,
      id: "binding_form",
      action_target_selected: {indices, entity_id}
    )

    {:noreply, socket}
  end

  def handle_info({:blueprint_applied, yaml, entity_id}, socket) do
    entity_search = if entity_id != "", do: entity_id, else: socket.assigns.entity_search

    {:noreply,
     assign(socket,
       binding_yaml: yaml,
       entity_search: entity_search,
       editor_mode: :yaml
     )}
  end

  def handle_info({:save_binding_yaml, yaml}, socket) do
    socket = assign(socket, binding_yaml: yaml)
    {:noreply, elem(do_save_binding(yaml, socket), 1)}
  end

  def handle_info({:condition_built, "output_condition_" <> idx_str, expr}, socket) do
    send_update(LoupeyWeb.BindingFormComponent,
      id: "binding_form",
      condition_update: {idx_str, expr}
    )

    {:noreply, socket}
  end

  def handle_info({:condition_built, "text_insert_" <> idx_str, expr}, socket) do
    send_update(LoupeyWeb.BindingFormComponent, id: "binding_form", text_insert: {idx_str, expr})
    {:noreply, socket}
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

  def handle_info({:put_flash, kind, msg}, socket) do
    {:noreply, put_flash(socket, kind, msg)}
  end

  def handle_info({:hide_dropdown, _id}, socket), do: {:noreply, socket}

  def handle_info({:update_yaml, yaml}, socket),
    do: {:noreply, assign(socket, binding_yaml: yaml, editor_mode: :yaml)}

  def handle_info(_msg, socket), do: {:noreply, socket}

  # -- Helpers --

  defp do_save_binding(yaml, socket) do
    layout = socket.assigns.active_layout
    control_id_str = format_control_id(socket.assigns.selected_control)
    entity_id = extract_entity_id(yaml)

    result =
      case socket.assigns.editing_binding do
        %Binding{id: id} when not is_nil(id) ->
          binding = Enum.find(layout.bindings, &(&1.id == id))
          Profiles.update_binding(binding, %{"yaml" => yaml, "entity_id" => entity_id})

        _ ->
          Profiles.create_binding(%{
            "layout_id" => layout.id,
            "control_id" => control_id_str,
            "entity_id" => entity_id,
            "yaml" => yaml
          })
      end

    case result do
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
  end

  defp reload_profile(socket, extra_key \\ nil, extra_val \\ nil) do
    profile = Profiles.get_profile(socket.assigns.profile.id)
    layouts = profile.layouts |> Enum.sort_by(& &1.position)

    active_layout =
      if socket.assigns.active_layout,
        do:
          Enum.find(layouts, &(&1.id == socket.assigns.active_layout.id)) || List.first(layouts),
        else: List.first(layouts)

    {editing_binding, binding_yaml} =
      if socket.assigns.selected_control && active_layout do
        control_id_str = format_control_id(socket.assigns.selected_control)
        existing = Enum.find(active_layout.bindings, &(&1.control_id == control_id_str))
        {existing, (existing && existing.yaml) || socket.assigns.binding_yaml}
      else
        {nil, ""}
      end

    socket =
      assign(socket,
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
    case Loupey.Devices.driver_for_type(device_type) do
      nil -> nil
      driver -> driver.device_spec()
    end
  end

  defp layout_bindings(nil), do: %{}
  defp layout_bindings(layout), do: Map.new(layout.bindings, &{&1.control_id, &1})

  defp update_yaml_entity(yaml, entity_id) do
    if String.contains?(yaml, "entity_id:"),
      do: Regex.replace(~r/entity_id:.*/, yaml, "entity_id: \"#{entity_id}\""),
      else: "entity_id: \"#{entity_id}\"\n" <> yaml
  end

  defp extract_entity_id(yaml) do
    case Regex.run(~r/entity_id:\s*"?([^"\n]+)"?/, yaml) do
      [_, id] -> String.trim(id)
      _ -> nil
    end
  end

  defp default_yaml do
    """
    input_rules: []
    output_rules:
      - when: true
        background: "#111111"
    """
  end
end
