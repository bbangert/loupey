defmodule LoupeyWeb.DashboardLive do
  use LoupeyWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Loupey.PubSub, "devices")
      Phoenix.PubSub.subscribe(Loupey.PubSub, "ha:connected")
    end

    status = Loupey.Orchestrator.status()
    ha_connected = Loupey.HA.connected?()

    ha_entity_count =
      try do
        length(Loupey.HA.get_all_states())
      rescue
        _ -> 0
      end

    {:ok,
     assign(socket,
       status: status,
       ha_connected: ha_connected,
       ha_entity_count: ha_entity_count
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <h1 class="text-2xl font-bold mb-6">Dashboard</h1>

      <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6">
        <%!-- Devices --%>
        <div class="bg-gray-800 rounded-lg p-6 border border-gray-700">
          <h2 class="text-lg font-semibold mb-4">Devices</h2>
          <div :if={@status.devices == []} class="text-gray-400 text-sm">
            No devices detected.
          </div>
          <div :for={device <- @status.devices} class="flex items-center justify-between py-2">
            <div class="flex items-center gap-3">
              <span class={[
                "w-2 h-2 rounded-full",
                if(device.connected, do: "bg-green-400", else: "bg-red-400")
              ]}>
              </span>
              <div>
                <span class="text-sm">{device.device_type || "Unknown"}</span>
                <span class="text-xs text-gray-500 ml-2">{device.tty}</span>
              </div>
            </div>
            <span :if={device.engine_running} class="text-xs bg-blue-900 text-blue-300 px-2 py-0.5 rounded">
              Engine
            </span>
          </div>

          <button
            phx-click="connect_devices"
            class="mt-3 text-xs bg-gray-700 hover:bg-gray-600 text-white px-3 py-1.5 rounded"
          >
            Scan & Connect
          </button>
        </div>

        <%!-- Home Assistant --%>
        <div class="bg-gray-800 rounded-lg p-6 border border-gray-700">
          <h2 class="text-lg font-semibold mb-4">Home Assistant</h2>
          <div class="flex items-center gap-3">
            <span class={[
              "w-2 h-2 rounded-full",
              if(@ha_connected, do: "bg-green-400", else: "bg-red-400")
            ]}>
            </span>
            <span class="text-sm">
              {if @ha_connected, do: "Connected (#{@ha_entity_count} entities)", else: "Not connected"}
            </span>
          </div>
          <div :if={!@ha_connected} class="mt-3">
            <a href="/settings" class="text-blue-400 hover:text-blue-300 text-sm">
              Configure connection &rarr;
            </a>
          </div>
        </div>

        <%!-- Active Profile --%>
        <div class="bg-gray-800 rounded-lg p-6 border border-gray-700">
          <h2 class="text-lg font-semibold mb-4">Active Profile</h2>
          <div :if={@status.active_profile} class="text-sm">
            <span class="text-white font-medium">{@status.active_profile.name}</span>
          </div>
          <div :if={!@status.active_profile} class="text-gray-400 text-sm">
            No profile active.
            <a href="/profiles" class="text-blue-400 hover:text-blue-300 ml-1">
              Activate one &rarr;
            </a>
          </div>
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("connect_devices", _params, socket) do
    Loupey.Orchestrator.connect_all_devices()

    {:noreply,
     socket
     |> assign(status: Loupey.Orchestrator.status())
     |> put_flash(:info, "Device scan complete")}
  end

  @impl true
  def handle_info(:ha_connected, socket) do
    ha_entity_count =
      try do
        length(Loupey.HA.get_all_states())
      rescue
        _ -> 0
      end

    {:noreply, assign(socket, ha_connected: true, ha_entity_count: ha_entity_count)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}
end
