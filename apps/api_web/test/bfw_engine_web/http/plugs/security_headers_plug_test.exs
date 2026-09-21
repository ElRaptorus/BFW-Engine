defmodule BfwEngineWeb.Http.Plugs.SecurityHeadersPlugTest do
  use ExUnit.Case, async: true

  alias BfwEngineWeb.Http.Plugs.SecurityHeadersPlug

  defp build_conn(scheme \\ :http) do
    %Plug.Conn{scheme: scheme, resp_headers: []}
  end

  defp get_header(conn, key) do
    case List.keyfind(conn.resp_headers, key, 0) do
      {_, value} -> value
      nil -> nil
    end
  end

  defp has_header?(conn, key) do
    Enum.any?(conn.resp_headers, fn {name, _} -> name == key end)
  end

  describe "call/2 — static headers always present" do
    test "sets x-content-type-options: nosniff" do
      conn = build_conn() |> SecurityHeadersPlug.call(SecurityHeadersPlug.init([]))
      assert get_header(conn, "x-content-type-options") == "nosniff"
    end

    test "sets x-frame-options: DENY" do
      conn = build_conn() |> SecurityHeadersPlug.call(SecurityHeadersPlug.init([]))
      assert get_header(conn, "x-frame-options") == "DENY"
    end

    test "sets referrer-policy" do
      conn = build_conn() |> SecurityHeadersPlug.call(SecurityHeadersPlug.init([]))
      assert get_header(conn, "referrer-policy") == "strict-origin-when-cross-origin"
    end

    test "sets permissions-policy" do
      conn = build_conn() |> SecurityHeadersPlug.call(SecurityHeadersPlug.init([]))
      assert get_header(conn, "permissions-policy") == "geolocation=(), camera=(), microphone=()"
    end
  end

  describe "call/2 — HSTS (scheme-conditional)" do
    test "does not set strict-transport-security on plain HTTP" do
      conn = build_conn(:http) |> SecurityHeadersPlug.call(SecurityHeadersPlug.init([]))
      refute has_header?(conn, "strict-transport-security")
    end

    test "sets strict-transport-security on HTTPS with 2-year max-age" do
      conn = build_conn(:https) |> SecurityHeadersPlug.call(SecurityHeadersPlug.init([]))
      hsts = get_header(conn, "strict-transport-security")
      assert hsts == "max-age=63072000; includeSubDomains"
    end

    test "HSTS value does not include preload directive" do
      conn = build_conn(:https) |> SecurityHeadersPlug.call(SecurityHeadersPlug.init([]))
      hsts = get_header(conn, "strict-transport-security")
      refute String.contains?(hsts, "preload")
    end
  end

  describe "call/2 — idempotency and non-interference" do
    test "does not modify existing resp_headers that differ from security headers" do
      conn =
        %Plug.Conn{scheme: :http, resp_headers: [{"content-type", "application/json"}]}
        |> SecurityHeadersPlug.call(SecurityHeadersPlug.init([]))

      assert get_header(conn, "content-type") == "application/json"
      assert get_header(conn, "x-content-type-options") == "nosniff"
    end

    test "conn is passed through unchanged when called with no-op opts" do
      conn = build_conn()
      result = SecurityHeadersPlug.call(conn, SecurityHeadersPlug.init([]))
      assert result.scheme == conn.scheme
    end
  end
end
