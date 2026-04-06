defmodule LoupeyWeb.Router do
  use LoupeyWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {LoupeyWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  scope "/", LoupeyWeb do
    pipe_through :browser

    live "/", DashboardLive, :index
    live "/profiles", ProfilesLive, :index
    live "/profiles/:id", ProfileEditorLive, :edit
    live "/settings", SettingsLive, :index
  end

  if Application.compile_env(:loupey, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser
      live_dashboard "/dashboard", metrics: LoupeyWeb.Telemetry
    end
  end
end
