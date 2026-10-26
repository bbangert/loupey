defmodule LoupeyWeb.SettingsLive do
  use LoupeyWeb, :live_view

  alias Loupey.Settings

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Loupey.HA.subscribe_connected()
      Loupey.HA.subscribe_status()
      Loupey.HA.subscribe_auth_failed()
    end

    ha_connected = Loupey.HA.ready?()
    saved_config = Settings.get_active_ha_config()

    {:ok,
     assign(socket,
       ha_connected: ha_connected,
       ha_url: (saved_config && saved_config.url) || "",
       ha_token: (saved_config && saved_config.token) || "",
       saved: saved_config != nil
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <h1 class="text-2xl font-bold mb-6">Settings</h1>

      <div class="bg-gray-800 rounded-lg p-6 border border-gray-700 max-w-xl">
        <h2 class="text-lg font-semibold mb-4">Home Assistant Connection</h2>

        <div class="flex items-center gap-3 mb-4">
          <span class={[
            "w-2 h-2 rounded-full",
            if(@ha_connected, do: "bg-green-400", else: "bg-red-400")
          ]}>
          </span>
          <span class="text-sm">
            {if @ha_connected, do: "Connected", else: "Not connected"}
          </span>
        </div>

        <form phx-submit="connect_ha" class="space-y-4">
          <div>
            <label class="block text-sm text-gray-400 mb-1">URL</label>
            <input
              type="text"
              name="url"
              value={@ha_url}
              placeholder="http://homeassistant.local:8123"
              class="w-full bg-gray-700 border border-gray-600 rounded-lg px-3 py-2 text-sm text-white"
            />
          </div>
          <div>
            <label class="block text-sm text-gray-400 mb-1">Long-Lived Access Token</label>
            <input
              type="password"
              name="token"
              value={@ha_token}
              placeholder="Your access token"
              class="w-full bg-gray-700 border border-gray-600 rounded-lg px-3 py-2 text-sm text-white"
            />
          </div>
          <button
            type="submit"
            class="bg-blue-600 hover:bg-blue-500 text-white text-sm px-4 py-2 rounded-lg"
          >
            {if @saved, do: "Save & Reconnect", else: "Save & Connect"}
          </button>
        </form>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("connect_ha", %{"url" => url, "token" => token}, socket) do
    # Persist to DB
    case Settings.save_ha_config(%{"url" => url, "token" => token}) do
      {:ok, _config} ->
        # Connect (or reconnect) to HA
        case Loupey.HA.connect(%Hassock.Config{url: url, token: token}) do
          # hassock 0.3 returns as soon as the connection process is up
          # and connects (and authenticates) in the background, so this
          # only means the connection is running, not that HA accepted us.
          # The status turns green on `:ha_connected` (handle_info below).
          {:ok, _pid} ->
            {:noreply,
             socket
             |> put_flash(:info, "Saved. Connecting to Home Assistant...")
             |> assign(ha_connected: false, ha_url: url, ha_token: token, saved: true)}

          {:error, :already_started} ->
            {:noreply,
             socket
             |> put_flash(:info, "Settings saved. Already connected.")
             |> assign(ha_url: url, ha_token: token, saved: true)}

          {:error, reason} ->
            {:noreply,
             socket
             |> put_flash(:error, "Saved but failed to connect: #{inspect(reason)}")
             |> assign(ha_connected: false, ha_url: url, ha_token: token, saved: true)}
        end

      {:error, changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to save: #{inspect(changeset.errors)}")}
    end
  end

  @impl true
  def handle_info(:ha_connected, socket) do
    {:noreply,
     socket
     |> assign(ha_connected: true)
     |> put_flash(:info, "Connected to Home Assistant")}
  end

  def handle_info({:ha_ready, ready?}, socket) do
    {:noreply, assign(socket, ha_connected: ready?)}
  end

  def handle_info({:ha_auth_failed, reason}, socket) do
    {:noreply,
     socket
     |> assign(ha_connected: false)
     |> put_flash(:error, "Home Assistant rejected the access token: #{inspect(reason)}")}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}
end
