defmodule LoupeyWeb.Router do
  use LoupeyWeb, :router

  # Content-Security-Policy for every browser page. All scripts, styles and
  # the LiveView socket are served from this origin; scripts get no inline
  # allowance. `style-src` keeps 'unsafe-inline' because the device grid
  # sizes its faces with server-rendered `style` attributes. `img-src` and
  # `font-src` allow `data:` for the inline icons/font in LiveDashboard's
  # stylesheet (dev only). `connect-src` is widened per request by
  # `put_socket_connect_src/2` below.
  # Kept as a literal header map so `mix sobelow` can verify it (Config.CSP).
  @browser_headers %{
    "content-security-policy" =>
      "default-src 'self'; base-uri 'self'; object-src 'none'; frame-ancestors 'self'; form-action 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self' data:; connect-src 'self'"
  }

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {LoupeyWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers, @browser_headers
    plug :put_socket_connect_src
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

    # LiveDashboard's layout has an inline bootstrap <script>, which the
    # browser pipeline's policy blocks. This pipeline runs after it and
    # re-issues the same policy with a per-request nonce that the dashboard
    # puts on its script tags (`csp_nonce_assign_key` below).
    pipeline :dashboard_csp do
      plug :put_dashboard_csp_nonce
    end

    scope "/dev" do
      pipe_through [:browser, :dashboard_csp]

      live_dashboard "/dashboard",
        metrics: LoupeyWeb.Telemetry,
        csp_nonce_assign_key: %{script: :csp_nonce, style: :csp_nonce}
    end

    defp put_dashboard_csp_nonce(conn, _opts) do
      nonce = 18 |> :crypto.strong_rand_bytes() |> Base.encode64()

      conn
      |> Plug.Conn.assign(:csp_nonce, nonce)
      |> update_csp(
        &String.replace(&1, "script-src 'self'", "script-src 'self' 'nonce-#{nonce}'")
      )
    end
  end

  # Safari (unlike Chrome/Firefox) does not let `connect-src 'self'` match
  # the same-origin ws:/wss: LiveView socket, so name that origin explicitly.
  # Cowboy takes host and port from the request's Host header, i.e. the
  # origin the browser used (a TLS proxy that forwards Host without a port
  # yields the scheme default, which is omitted). A Host that isn't a plain
  # hostname/IP[:port] is left out rather than spliced into the header.
  defp put_socket_connect_src(conn, _opts) do
    case socket_origin(conn) do
      nil ->
        conn

      origin ->
        update_csp(
          conn,
          &String.replace(
            &1,
            "connect-src 'self'",
            "connect-src 'self' ws://#{origin} wss://#{origin}"
          )
        )
    end
  end

  defp socket_origin(%Plug.Conn{host: host, port: port}) do
    if host =~ ~r/\A(?:[A-Za-z0-9.-]+|\[[0-9A-Fa-f:.]+\])\z/ do
      if port in [80, 443], do: host, else: "#{host}:#{port}"
    end
  end

  defp update_csp(conn, fun) do
    case Plug.Conn.get_resp_header(conn, "content-security-policy") do
      [policy] -> Plug.Conn.put_resp_header(conn, "content-security-policy", fun.(policy))
      _ -> conn
    end
  end
end
