defmodule LoupeyWeb.BlueprintPicker do
  @moduledoc """
  LiveComponent for selecting and applying binding blueprints.

  Shows a dropdown of available blueprints. When one is selected,
  renders an input form with typed fields based on the blueprint's
  declared inputs. On submit, sends `{:blueprint_applied, yaml}` to parent.
  """
  use LoupeyWeb, :live_component

  alias Loupey.Bindings.Blueprints

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(:blueprints, assigns[:blueprints] || Blueprints.list())
     |> assign(:entity_search, assigns[:entity_search] || "")
     |> assign(:selected, socket.assigns[:selected])}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <label class="block text-xs text-gray-400 mb-1">Start from Blueprint</label>
      <form phx-change="select" phx-target={@myself}>
        <select
          name="blueprint"
          class="w-full bg-gray-700 border border-gray-600 rounded px-2 py-1 text-sm text-white"
        >
          <option value="">— Choose a blueprint —</option>
          <option :for={bp <- @blueprints} value={bp.id}>{bp.name} — {bp.description}</option>
        </select>
      </form>

      <div :if={@selected} class="mt-2 bg-gray-900 rounded p-3 border border-gray-700">
        <div class="flex items-center justify-between mb-2">
          <h3 class="text-xs font-semibold text-blue-400">{@selected.name}</h3>
          <button phx-click="cancel" phx-target={@myself} class="text-[10px] text-gray-400 hover:text-white">
            Cancel
          </button>
        </div>
        <form phx-submit="apply" phx-target={@myself} class="space-y-2">
          <input type="hidden" name="blueprint_id" value={@selected.id} />
          <div :for={{name, config} <- @selected.inputs}>
            <label class="block text-[10px] text-gray-500 mb-0.5">{config.description || name}</label>
            <.blueprint_field name={name} config={config} entity_search={@entity_search} />
          </div>
          <button
            type="submit"
            class="w-full bg-blue-600 hover:bg-blue-500 text-white text-xs px-3 py-2 rounded-lg mt-2"
          >
            Apply Blueprint
          </button>
        </form>
      </div>
    </div>
    """
  end

  defp blueprint_field(assigns) do
    type = assigns.config.type
    default = assigns.config[:default] || ""

    assigns =
      assigns
      |> Map.put(:type, type)
      |> Map.put(:input_name, "inputs[#{assigns.name}]")
      |> Map.put(:default, default)

    ~H"""
    <div :if={@type == "entity"}>
      <.live_component
        module={LoupeyWeb.EntityAutocomplete}
        id={"bp_entity_#{@name}"}
        value={@entity_search}
        name={@input_name}
      />
    </div>
    <input
      :if={@type == "string"}
      type="text"
      name={@input_name}
      value={@default}
      class="w-full bg-gray-700 border border-gray-600 rounded px-1.5 py-1 text-xs text-white"
    />
    <input
      :if={@type == "color"}
      type="color"
      name={@input_name}
      value={@default}
      class="w-full h-7 bg-gray-700 border border-gray-600 rounded cursor-pointer"
    />
    <input
      :if={@type == "number"}
      type="number"
      name={@input_name}
      value={@default}
      class="w-full bg-gray-700 border border-gray-600 rounded px-1.5 py-1 text-xs text-white"
    />
    <input
      :if={@type == "icon"}
      type="text"
      name={@input_name}
      value={@default}
      placeholder="icons/neon_blue/Lights_On.png"
      class="w-full bg-gray-700 border border-gray-600 rounded px-1.5 py-1 text-xs text-white"
    />
    """
  end

  @impl true
  def handle_event("select", %{"blueprint" => ""}, socket) do
    {:noreply, assign(socket, selected: nil)}
  end

  def handle_event("select", %{"blueprint" => id}, socket) do
    bp = Enum.find(socket.assigns.blueprints, &(&1.id == id))
    {:noreply, assign(socket, selected: bp)}
  end

  def handle_event("cancel", _params, socket) do
    {:noreply, assign(socket, selected: nil)}
  end

  def handle_event("apply", %{"blueprint_id" => id, "inputs" => inputs}, socket) do
    case Blueprints.instantiate(id, inputs) do
      {:ok, yaml} ->
        entity_id = Map.get(inputs, "entity", "")
        send(self(), {:blueprint_applied, yaml, entity_id})
        {:noreply, assign(socket, selected: nil)}

      {:error, reason} ->
        send(self(), {:put_flash, :error, "Blueprint failed: #{inspect(reason)}"})
        {:noreply, socket}
    end
  end
end
