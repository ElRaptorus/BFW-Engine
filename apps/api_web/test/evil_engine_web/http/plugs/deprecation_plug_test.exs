defmodule EvilEngineWeb.Http.Plugs.DeprecationPlugTest do
  use ExUnit.Case, async: true

  alias EvilEngineWeb.Http.Plugs.DeprecationPlug

  defp build_conn(private_data \\ %{}) do
    %Plug.Conn{
      private: private_data,
      resp_headers: []
    }
  end

  describe "call/2" do
    test "non-deprecated route returns no deprecation headers" do
      conn = build_conn()
      result = DeprecationPlug.call(conn, DeprecationPlug.init([]))

      refute has_header?(result, "deprecation")
      refute has_header?(result, "link")
      refute has_header?(result, "sunset")
    end

    test "deprecated route returns deprecation and link headers" do
      conn = build_conn(%{deprecated: %{successor: "/api/v2/processes", sunset: nil}})
      result = DeprecationPlug.call(conn, DeprecationPlug.init([]))

      assert get_header(result, "deprecation") == "true"
      assert get_header(result, "link") == "</api/v2/processes>; rel=\"successor-version\""
      refute has_header?(result, "sunset")
    end

    test "deprecated route with sunset includes sunset header in RFC 7231 HTTP-date format" do
      sunset = ~U[2027-06-15 12:00:00Z]
      conn = build_conn(%{deprecated: %{successor: "/api/v2/tasks", sunset: sunset}})
      result = DeprecationPlug.call(conn, DeprecationPlug.init([]))

      assert get_header(result, "deprecation") == "true"
      assert get_header(result, "link") == "</api/v2/tasks>; rel=\"successor-version\""
      assert get_header(result, "sunset") == "Tue, 15 Jun 2027 12:00:00 GMT"
    end

    test "no crash when deprecated map has no successor key" do
      conn = build_conn(%{deprecated: %{}})
      result = DeprecationPlug.call(conn, DeprecationPlug.init([]))

      refute has_header?(result, "deprecation")
    end

    test "no crash when deprecated is nil" do
      conn = build_conn(%{deprecated: nil})
      result = DeprecationPlug.call(conn, DeprecationPlug.init([]))

      refute has_header?(result, "deprecation")
    end
  end

  defp has_header?(conn, key) do
    Enum.any?(conn.resp_headers, fn {header_name, _value} -> header_name == key end)
  end

  defp get_header(conn, key) do
    case List.keyfind(conn.resp_headers, key, 0) do
      {_header_name, value} -> value
      nil -> nil
    end
  end
end
