defmodule LoupeyWeb.RouterTest do
  @moduledoc """
  The browser pipeline must send a Content-Security-Policy (Sobelow
  Config.CSP) that keeps scripts same-origin with no inline allowance.
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
    assert "connect-src 'self'" in directives
    assert "object-src 'none'" in directives
    refute policy =~ "unsafe-eval"

    refute Enum.any?(
             directives,
             &(String.starts_with?(&1, "script-src") and &1 =~ "unsafe-inline")
           )
  end
end
