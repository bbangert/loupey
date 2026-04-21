defmodule LoupeyWeb.EntityAutocomplete do
  @moduledoc """
  Reusable entity autocomplete LiveComponent.

  Shows a text input that searches HA entities as you type,
  with a dropdown of matches. Sends `{:entity_selected, id, entity_id}`
  to the parent when an entity is picked.

  ## Usage

      <.live_component
        module={LoupeyWeb.EntityAutocomplete}
        id="my_entity_picker"
        value="light.living_room"
        name="entity_id"
      />

  Parent handles:

      def handle_info({:entity_selected, "my_entity_picker", entity_id}, socket)
  """

  use LoupeyWeb, :live_component

  @impl true
  def update(assigns, socket) do
    # Only update the search text if the parent changed the value externally
    prev_value = socket.assigns[:parent_value]
    new_value = assigns[:value] || ""
    value_changed = prev_value != new_value

    search =
      if value_changed or !socket.assigns[:search] do
        new_value
      else
        socket.assigns.search
      end

    {:ok,
     socket
     |> assign(:component_id, assigns[:id])
     |> assign(:parent_value, new_value)
     |> assign(:input_name, assigns[:name] || "entity_id")
     |> assign(:placeholder, assigns[:placeholder] || "Start typing... e.g. light.")
     |> assign(:domain_filter, assigns[:domain] || socket.assigns[:domain_filter])
     |> assign(:search, search)
     |> assign(:matches, socket.assigns[:matches] || [])
     |> assign(:show_dropdown, socket.assigns[:show_dropdown] || false)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="relative">
      <input
        type="text"
        name={@input_name}
        phx-keyup="search"
        phx-focus="focus"
        phx-blur="blur"
        phx-debounce="100"
        phx-target={@myself}
        value={@search}
        placeholder={@placeholder}
        autocomplete="off"
        class="w-full bg-gray-700 border border-gray-600 rounded px-2 py-1 text-sm text-white"
      />
      <div
        :if={@show_dropdown and @matches != []}
        class="absolute z-10 w-full mt-1 bg-gray-900 border border-gray-600 rounded-lg max-h-48 overflow-y-auto shadow-lg"
      >
        <button
          :for={id <- @matches}
          type="button"
          phx-click="pick"
          phx-target={@myself}
          phx-value-entity={id}
          class="block w-full text-left text-xs text-gray-300 hover:text-white hover:bg-gray-700 px-2 py-1 truncate"
        >
          {id}
        </button>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("search", %{"value" => query}, socket) do
    matches = search_entities(query, socket.assigns.domain_filter)
    {:noreply, assign(socket, search: query, matches: matches, show_dropdown: matches != [])}
  end

  def handle_event("focus", _params, socket) do
    matches = search_entities(socket.assigns.search, socket.assigns.domain_filter)
    {:noreply, assign(socket, show_dropdown: matches != [], matches: matches)}
  end

  def handle_event("blur", _params, socket) do
    Process.send_after(self(), {:hide_dropdown, socket.assigns.component_id}, 200)
    {:noreply, socket}
  end

  def handle_event("pick", %{"entity" => entity_id}, socket) do
    send(self(), {:entity_selected, socket.assigns.component_id, entity_id})
    {:noreply, assign(socket, search: entity_id, matches: [], show_dropdown: false)}
  end

  defp search_entities(query, domain_filter) when byte_size(query) >= 1 do
    Loupey.HA.get_all_states()
    |> Enum.map(& &1.entity_id)
    |> filter_by_domain(domain_filter)
    |> Enum.filter(&String.contains?(&1, query))
    |> Enum.sort()
    |> Enum.take(20)
  rescue
    _ -> []
  end

  defp search_entities(_, domain_filter) do
    # If no query but there's a domain filter, show all entities in that domain
    if domain_filter && domain_filter != "" do
      search_entities(domain_filter <> ".", domain_filter)
    else
      []
    end
  end

  defp filter_by_domain(ids, nil), do: ids
  defp filter_by_domain(ids, ""), do: ids

  defp filter_by_domain(ids, domain),
    do: Enum.filter(ids, &String.starts_with?(&1, domain <> "."))
end
