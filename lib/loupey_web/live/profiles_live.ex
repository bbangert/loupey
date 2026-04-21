defmodule LoupeyWeb.ProfilesLive do
  use LoupeyWeb, :live_view

  alias Loupey.Profiles

  @impl true
  def mount(_params, _session, socket) do
    profiles = Profiles.list_profiles()

    device_types =
      Loupey.Devices.all_device_specs()
      |> Enum.map(& &1.type)
      |> Enum.uniq()

    {:ok,
     assign(socket,
       profiles: profiles,
       device_types: device_types,
       show_new_form: false,
       new_name: "",
       new_device_type: List.first(device_types)
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <div class="flex items-center justify-between mb-6">
        <h1 class="text-2xl font-bold">Profiles</h1>
        <button
          phx-click="toggle_new_form"
          class="bg-blue-600 hover:bg-blue-500 text-white text-sm px-4 py-2 rounded-lg"
        >
          New Profile
        </button>
      </div>

      <%!-- New profile form --%>
      <div :if={@show_new_form} class="bg-gray-800 rounded-lg p-6 border border-gray-700 mb-6 max-w-md">
        <form phx-submit="create_profile" class="space-y-4">
          <div>
            <label class="block text-sm text-gray-400 mb-1">Name</label>
            <input
              type="text"
              name="name"
              value={@new_name}
              placeholder="My Profile"
              autofocus
              class="w-full bg-gray-700 border border-gray-600 rounded-lg px-3 py-2 text-sm text-white"
            />
          </div>
          <div>
            <label class="block text-sm text-gray-400 mb-1">Device Type</label>
            <select
              name="device_type"
              class="w-full bg-gray-700 border border-gray-600 rounded-lg px-3 py-2 text-sm text-white"
            >
              <option :for={dt <- @device_types} value={dt} selected={dt == @new_device_type}>
                {dt}
              </option>
            </select>
          </div>
          <div class="flex gap-2">
            <button
              type="submit"
              class="bg-blue-600 hover:bg-blue-500 text-white text-sm px-4 py-2 rounded-lg"
            >
              Create
            </button>
            <button
              type="button"
              phx-click="toggle_new_form"
              class="bg-gray-600 hover:bg-gray-500 text-white text-sm px-4 py-2 rounded-lg"
            >
              Cancel
            </button>
          </div>
        </form>
      </div>

      <%!-- Profile list --%>
      <div :if={@profiles == [] and !@show_new_form} class="bg-gray-800 rounded-lg p-8 text-center border border-gray-700">
        <p class="text-gray-400">No profiles yet. Create one to get started.</p>
      </div>

      <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
        <div
          :for={profile <- @profiles}
          class="bg-gray-800 rounded-lg p-5 border border-gray-700 hover:border-gray-500 transition"
        >
          <div class="flex items-start justify-between mb-3">
            <div>
              <h3 class="font-semibold text-white">{profile.name}</h3>
              <p class="text-xs text-gray-400 mt-1">{profile.device_type}</p>
            </div>
            <div :if={profile.active} class="text-xs bg-green-900 text-green-300 px-2 py-1 rounded">
              Active
            </div>
          </div>
          <div class="flex gap-2 mt-4">
            <a
              href={~p"/profiles/#{profile.id}"}
              class="text-sm bg-gray-700 hover:bg-gray-600 text-white px-3 py-1.5 rounded-lg"
            >
              Edit
            </a>
            <button
              :if={!profile.active}
              phx-click="activate_profile"
              phx-value-id={profile.id}
              class="text-sm bg-green-800 hover:bg-green-700 text-white px-3 py-1.5 rounded-lg"
            >
              Activate
            </button>
            <button
              :if={profile.active}
              phx-click="deactivate_profile"
              phx-value-id={profile.id}
              class="text-sm bg-yellow-800 hover:bg-yellow-700 text-white px-3 py-1.5 rounded-lg"
            >
              Deactivate
            </button>
            <button
              phx-click="delete_profile"
              phx-value-id={profile.id}
              data-confirm="Delete this profile?"
              class="text-sm bg-red-900 hover:bg-red-800 text-red-300 px-3 py-1.5 rounded-lg"
            >
              Delete
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("toggle_new_form", _params, socket) do
    {:noreply, assign(socket, show_new_form: !socket.assigns.show_new_form)}
  end

  def handle_event("create_profile", %{"name" => name, "device_type" => device_type}, socket) do
    case Profiles.create_profile(%{"name" => name, "device_type" => device_type}) do
      {:ok, _profile} ->
        {:noreply,
         socket
         |> put_flash(:info, "Profile created")
         |> assign(profiles: Profiles.list_profiles(), show_new_form: false)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to create profile")}
    end
  end

  def handle_event("delete_profile", %{"id" => id}, socket) do
    profile = Profiles.get_profile(String.to_integer(id))

    if profile do
      Profiles.delete_profile(profile)
    end

    {:noreply, assign(socket, profiles: Profiles.list_profiles())}
  end

  def handle_event("activate_profile", %{"id" => id}, socket) do
    case Loupey.Orchestrator.activate_profile(String.to_integer(id)) do
      {:ok, _profile} ->
        {:noreply,
         socket
         |> put_flash(:info, "Profile activated and engines started")
         |> assign(profiles: Profiles.list_profiles())}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to activate: #{inspect(reason)}")}
    end
  end

  def handle_event("deactivate_profile", %{"id" => id}, socket) do
    Loupey.Orchestrator.deactivate_profile(String.to_integer(id))

    {:noreply,
     socket
     |> put_flash(:info, "Profile deactivated")
     |> assign(profiles: Profiles.list_profiles())}
  end
end
