defmodule BfwEngineWeb.Http.Plugs.DevtoolsGatePlugTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias BfwEngineWeb.Http.Plugs.DevtoolsGatePlug

  setup do
    prev_devtools = Application.get_env(:api_web, :devtools_enabled)
    prev_expose = Application.get_env(:api_web, :expose_openapi_spec)

    on_exit(fn ->
      if prev_devtools do
        Application.put_env(:api_web, :devtools_enabled, prev_devtools)
      else
        Application.delete_env(:api_web, :devtools_enabled)
      end

      if prev_expose do
        Application.put_env(:api_web, :expose_openapi_spec, prev_expose)
      else
        Application.delete_env(:api_web, :expose_openapi_spec)
      end
    end)

    :ok
  end

  describe "init/1" do
    test "passes options through unchanged" do
      assert DevtoolsGatePlug.init([]) == []

      assert DevtoolsGatePlug.init(allow_if: :expose_openapi_spec) == [
               allow_if: :expose_openapi_spec
             ]
    end
  end

  describe "call/2 with devtools enabled" do
    test "passes request through" do
      Application.put_env(:api_web, :devtools_enabled, true)

      conn = build_conn()
      result = DevtoolsGatePlug.call(conn, [])

      refute result.halted
      refute result.state == :sent
    end

    test "passes request through even with allow_if flag false" do
      Application.put_env(:api_web, :devtools_enabled, true)
      Application.put_env(:api_web, :expose_openapi_spec, false)

      conn = build_conn()
      result = DevtoolsGatePlug.call(conn, allow_if: :expose_openapi_spec)

      refute result.halted
    end
  end

  describe "call/2 with devtools disabled" do
    test "returns 404 with plain text body" do
      Application.put_env(:api_web, :devtools_enabled, false)

      conn = build_conn()
      result = DevtoolsGatePlug.call(conn, [])

      assert result.halted
      assert result.status == 404
      assert result.resp_body == "Not Found"
      assert has_content_type?(result, "text/plain")
    end

    test "returns 404 when allow_if flag is also false" do
      Application.put_env(:api_web, :devtools_enabled, false)
      Application.put_env(:api_web, :expose_openapi_spec, false)

      conn = build_conn()
      result = DevtoolsGatePlug.call(conn, allow_if: :expose_openapi_spec)

      assert result.halted
      assert result.status == 404
    end

    test "passes through when allow_if override flag is true" do
      Application.put_env(:api_web, :devtools_enabled, false)
      Application.put_env(:api_web, :expose_openapi_spec, true)

      conn = build_conn()
      result = DevtoolsGatePlug.call(conn, allow_if: :expose_openapi_spec)

      refute result.halted
    end
  end

  describe "call/2 default config" do
    test "defaults to enabled when no config is set" do
      Application.delete_env(:api_web, :devtools_enabled)

      conn = build_conn()
      result = DevtoolsGatePlug.call(conn, [])

      refute result.halted
    end
  end

  defp build_conn do
    conn(:get, "/")
  end

  defp has_content_type?(conn, expected) do
    Enum.any?(conn.resp_headers, fn
      {"content-type", ct} -> ct =~ expected
      _ -> false
    end)
  end
end
