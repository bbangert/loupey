defmodule LoupeyWeb.DashboardLive do
  use LoupeyWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Loupey.PubSub, "devices")
      Phoenix.PubSub.subscribe(Loupey.PubSub, "ha:status")
    end

    devices = Loupey.Devices.discover()
    ha_connected = Process.whereis(Loupey.HA.Connection) != nil

    ha_entity_count =
      try do
        length(Loupey.HA.get_all_states())
      rescue
        _ -> 0
      end

    {:ok,
     assign(socket,
       devices: devices,
       ha_connected: ha_connected,
       ha_entity_count: ha_entity_count
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <h1 class="text-2xl font-bold mb-6">Dashboard</h1>

      <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
        <%!-- Devices --%>
        <div class="bg-gray-800 rounded-lg p-6 border border-gray-700">
          <h2 class="text-lg font-semibold mb-4">Devices</h2>
          <div :if={@devices == []} class="text-gray-400">
            No devices detected.
          </div>
          <div :for={{driver, tty} <- @devices} class="flex items-center gap-3 py-2">
            <span class="w-2 h-2 rounded-full bg-green-400"></span>
            <span class="text-sm">{inspect(driver)} on {tty}</span>
          </div>
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
      </div>
    </div>
    """
  end
end
