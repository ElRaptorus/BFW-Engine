defmodule BfwEngineWeb.Http.RoutesTest do
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias BfwEngine.Auth.ProviderRegistry
  alias BfwEngine.Test.HttpAuthHelper
  alias BfwEngineWeb.Http.OpenApiSpecLoader

  @router BfwEngineWeb.Http.Router

  setup do
    ProviderRegistry.reset_to_default()
    :ok
  end

  defp call(conn) do
    @router.call(conn, @router.init([]))
  end

  # --- Public routes (no auth required) ------------------------------------

  describe "GET /health" do
    test "returns 204 with no body" do
      conn = conn(:get, "/health") |> call()

      assert conn.status == 204
      assert conn.resp_body == ""
    end
  end

  describe "GET /info" do
    test "returns 200 with engine identity" do
      conn = conn(:get, "/info") |> call()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert Map.has_key?(body, "engineId")
      assert Map.has_key?(body, "engineName")
      assert Map.has_key?(body, "version")
      assert Map.has_key?(body, "startedAt")
      refute Map.has_key?(body, "authDisabled")
      refute Map.has_key?(body, "eventSinkDatabase")
      refute Map.has_key?(body, "uptimeSeconds")
    end
  end

  # --- Authenticated routes -----------------------------------------------

  describe "GET /stats without auth" do
    setup do
      previous = Application.get_env(:api_auth, :auth_disabled)
      Application.put_env(:api_auth, :auth_disabled, false)
      on_exit(fn -> Application.put_env(:api_auth, :auth_disabled, previous) end)
      :ok
    end

    test "returns 401 when auth is enabled" do
      conn = conn(:get, "/stats") |> call()

      assert conn.status == 401
      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "unauthorized"
    end
  end

  describe "GET /stats with valid JWT" do
    setup do
      previous = Application.get_env(:api_auth, :auth_disabled)
      Application.put_env(:api_auth, :auth_disabled, false)
      on_exit(fn -> Application.put_env(:api_auth, :auth_disabled, previous) end)
      :ok
    end

    test "returns 200 with snapshot data" do
      token = HttpAuthHelper.sign_jwt()

      conn =
        conn(:get, "/stats")
        |> put_req_header("authorization", "Bearer #{token}")
        |> call()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert Map.has_key?(body, "engine")
      assert Map.has_key?(body, "processInstances")
      assert Map.has_key?(body, "listeners")
    end
  end

  describe "GET /stats with auth disabled" do
    setup do
      previous = Application.get_env(:api_auth, :auth_disabled)
      Application.put_env(:api_auth, :auth_disabled, true)
      on_exit(fn -> Application.put_env(:api_auth, :auth_disabled, previous) end)
      :ok
    end

    test "returns 200 with snapshot" do
      conn = conn(:get, "/stats") |> call()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert Map.has_key?(body, "engine")
    end
  end

  # --- Swagger UI & OpenAPI spec -------------------------------------------

  describe "GET / (Swagger UI)" do
    test "returns HTML containing Swagger UI" do
      conn =
        conn(:get, "/")
        |> put_req_header("accept", "text/html")
        |> call()

      assert conn.status == 200
      assert {"content-type", content_type} = List.keyfind(conn.resp_headers, "content-type", 0)
      assert content_type =~ "text/html"
      assert conn.resp_body =~ "swagger"
    end
  end

  describe "GET /api/openapi" do
    test "returns valid JSON with OpenAPI 3.x structure" do
      conn = conn(:get, "/api/openapi") |> call()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["openapi"] =~ "3."
      assert body["info"]["title"] == "Bifrost Forge World Engine API"
      assert is_map(body["paths"])
      assert Map.has_key?(body["paths"], "/health")
      assert Map.has_key?(body["paths"], "/info")
      assert Map.has_key?(body["paths"], "/stats")
    end

    test "servers block is injected from runtime endpoint port" do
      OpenApiSpecLoader.reload!()
      conn = conn(:get, "/api/openapi") |> call()

      body = Jason.decode!(conn.resp_body)
      assert [%{"url" => url} | _] = body["servers"]
      assert url == "http://localhost:4002"
    end
  end

  # --- Devtools gating -------------------------------------------------------

  describe "GET / (Swagger UI) with devtools disabled" do
    setup do
      previous = Application.get_env(:api_web, :devtools_enabled)
      Application.put_env(:api_web, :devtools_enabled, false)
      on_exit(fn -> Application.put_env(:api_web, :devtools_enabled, previous) end)
      :ok
    end

    test "returns 404" do
      conn = conn(:get, "/") |> put_req_header("accept", "text/html") |> call()

      assert conn.status == 404
      assert conn.resp_body == "Not Found"
    end
  end

  describe "GET /api/openapi with devtools disabled" do
    setup do
      previous_devtools = Application.get_env(:api_web, :devtools_enabled)
      previous_expose = Application.get_env(:api_web, :expose_openapi_spec)
      Application.put_env(:api_web, :devtools_enabled, false)
      Application.put_env(:api_web, :expose_openapi_spec, false)

      on_exit(fn ->
        Application.put_env(:api_web, :devtools_enabled, previous_devtools)
        Application.put_env(:api_web, :expose_openapi_spec, previous_expose)
      end)

      :ok
    end

    test "returns 404 when both flags are off" do
      conn = conn(:get, "/api/openapi") |> call()

      assert conn.status == 404
    end
  end

  describe "GET /api/openapi with expose_openapi_spec override" do
    setup do
      previous_devtools = Application.get_env(:api_web, :devtools_enabled)
      previous_expose = Application.get_env(:api_web, :expose_openapi_spec)
      Application.put_env(:api_web, :devtools_enabled, false)
      Application.put_env(:api_web, :expose_openapi_spec, true)

      on_exit(fn ->
        Application.put_env(:api_web, :devtools_enabled, previous_devtools)
        Application.put_env(:api_web, :expose_openapi_spec, previous_expose)
      end)

      :ok
    end

    test "returns 200 when expose_openapi_spec is true despite devtools off" do
      conn = conn(:get, "/api/openapi") |> call()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["openapi"] =~ "3."
    end
  end

  # --- 404 ----------------------------------------------------------------

  describe "unknown route" do
    test "unmatched routes return 404 from the plugin extension catch-all" do
      conn = conn(:get, "/nonexistent") |> call()

      assert conn.status == 404
      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "not_found"
    end
  end
end
