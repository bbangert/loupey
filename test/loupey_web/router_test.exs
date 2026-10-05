defmodule LoupeyWeb.RouterTest do
  @moduledoc """
  The browser pipeline must send a Content-Security-Policy (Sobelow
  Config.CSP) that keeps scripts same-origin with no inline allowance, and
  the dev LiveDashboard's inline script must be allowed only by nonce.
  """

  use ExUnit.Case, async: true

  import Phoenix.ConnTest

  @endpoint LoupeyWeb.Endpoint

  test "browser pages carry a same-origin Content-Security-Policy" do
    # Run only the :browser pipeline; the LiveViews behind it need the repo.
    conn =
      build_conn()
      |> bypass_through(LoupeyWeb.Router, [:browser])
      |> get("/")

    assert [policy] = Plug.Conn.get_resp_header(conn, "content-security-policy")
    directives = policy |> String.split(";") |> Enum.map(&String.trim/1)

    assert "default-src 'self'" in directives
    assert "script-src 'self'" in directives
    assert Enum.any?(directives, &String.starts_with?(&1, "connect-src 'self'"))
    assert "object-src 'none'" in directives
    refute policy =~ "unsafe-eval"

    refute Enum.any?(
             directives,
             &(String.starts_with?(&1, "script-src") and &1 =~ "unsafe-inline")
           )
  end

  describe "connect-src names the LiveView socket origin (Safari)" do
    defp connect_src(url), do: build_conn() |> browser_get(url) |> connect_directive()

    # Phoenix.ConnTest can't express an IPv6 host in a URL, so set the
    # conn's host/port the way Cowboy reports them (unbracketed).
    defp connect_src_for(host, port),
      do: %{build_conn() | host: host, port: port} |> browser_get("/") |> connect_directive()

    defp browser_get(conn, url),
      do: conn |> bypass_through(LoupeyWeb.Router, [:browser]) |> get(url)

    defp connect_directive(conn) do
      [policy] = Plug.Conn.get_resp_header(conn, "content-security-policy")

      policy
      |> String.split(";")
      |> Enum.map(&String.trim/1)
      |> Enum.find(&String.starts_with?(&1, "connect-src"))
    end

    test "includes the request's host and non-default port" do
      assert connect_src("http://loupey.local:4000/") ==
               "connect-src 'self' ws://loupey.local:4000 wss://loupey.local:4000"
    end

    test "port 80 is only the ws:// default" do
      assert connect_src("http://loupey.local/") ==
               "connect-src 'self' ws://loupey.local wss://loupey.local:80"
    end

    test "port 443 is only the wss:// default" do
      assert connect_src("https://loupey.local/") ==
               "connect-src 'self' ws://loupey.local:443 wss://loupey.local"
    end

    test "brackets an IPv6 literal on a non-default port" do
      assert connect_src_for("::1", 4000) == "connect-src 'self' ws://[::1]:4000 wss://[::1]:4000"
    end

    test "brackets a bare IPv6 literal on port 80" do
      assert connect_src_for("::1", 80) == "connect-src 'self' ws://[::1] wss://[::1]:80"
    end

    test "never splices a malformed host into the policy" do
      conn =
        %{build_conn() | host: "evil.test; script-src *"}
        |> bypass_through(LoupeyWeb.Router, [:browser])
        |> get("/")

      [policy] = Plug.Conn.get_resp_header(conn, "content-security-policy")
      refute policy =~ "evil"
      assert policy =~ "connect-src 'self'"
    end
  end

  test "dev LiveDashboard gets a per-request script nonce that matches its script tags" do
    conn = get(build_conn(), "/dev/dashboard/home")
    assert conn.status == 200

    assert [policy] = Plug.Conn.get_resp_header(conn, "content-security-policy")
    assert [_, nonce] = Regex.run(~r/script-src 'self' 'nonce-([^']+)'/, policy)
    assert policy =~ "connect-src 'self' ws://"
    assert conn.resp_body =~ ~s(<script nonce="#{nonce}")
    refute conn.resp_body =~ ~r/<script(?![^>]*nonce=)[^>]*>\s*\S/

    # A fresh nonce on every request.
    other = get(build_conn(), "/dev/dashboard/home")
    refute Plug.Conn.get_resp_header(other, "content-security-policy") == [policy]
  end
end
