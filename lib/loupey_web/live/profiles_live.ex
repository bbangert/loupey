defmodule LoupeyWeb.ProfilesLive do
  use LoupeyWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, profiles: [])}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <div class="flex items-center justify-between mb-6">
        <h1 class="text-2xl font-bold">Profiles</h1>
        <button class="bg-blue-600 hover:bg-blue-500 text-white text-sm px-4 py-2 rounded-lg">
          New Profile
        </button>
      </div>

      <div :if={@profiles == []} class="bg-gray-800 rounded-lg p-8 text-center border border-gray-700">
        <p class="text-gray-400">No profiles yet. Create one to get started.</p>
      </div>
    </div>
    """
  end
end
