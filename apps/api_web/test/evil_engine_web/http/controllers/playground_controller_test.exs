defmodule EvilEngineWeb.Http.PlaygroundControllerTest do
  use ExUnit.Case, async: false

  import Plug.Test

  @router EvilEngineWeb.Http.Router

  setup do
    previous = Application.get_env(:api_web, :devtools_enabled)
    Application.put_env(:api_web, :devtools_enabled, true)

    on_exit(fn ->
      if previous do
        Application.put_env(:api_web, :devtools_enabled, previous)
      else
        Application.delete_env(:api_web, :devtools_enabled)
      end
    end)

    :ok
  end

  defp call(conn) do
    @router.call(conn, @router.init([]))
  end

  describe "GET /admin/graphiql" do
    test "returns 200 with HTML content type" do
      conn = conn(:get, "/admin/graphiql") |> call()

      assert conn.status == 200
      assert has_content_type?(conn, "text/html")
    end

    test "HTML contains GraphQL Playground CDN assets" do
      conn = conn(:get, "/admin/graphiql") |> call()

      assert conn.resp_body =~ "graphql-playground-react/build/static/css/index.css"
      assert conn.resp_body =~ "graphql-playground-react/build/static/js/middleware.js"
    end

    test "HTML contains the GraphQL endpoint" do
      conn = conn(:get, "/admin/graphiql") |> call()

      assert conn.resp_body =~ "/api/v1/graphql"
    end

    test "HTML contains all example tab names" do
      conn = conn(:get, "/admin/graphiql") |> call()

      assert conn.resp_body =~ "List Processes"
      assert conn.resp_body =~ "Get Process by ID"
      assert conn.resp_body =~ "List Process Versions"
      assert conn.resp_body =~ "List Process Instances"
      assert conn.resp_body =~ "Get Process Instance"
      assert conn.resp_body =~ "List Flow Node Instances"
      assert conn.resp_body =~ "Get Flow Node Instance"
      assert conn.resp_body =~ "List Data Object Values"
      assert conn.resp_body =~ "List Data Object History"
      assert conn.resp_body =~ "List Decision Definitions"
      assert conn.resp_body =~ "Get Decision Definition"
      assert conn.resp_body =~ "List Decision Versions"
      assert conn.resp_body =~ "Get Decision Version"
      assert conn.resp_body =~ "Get Process Version"
      assert conn.resp_body =~ "Get Data Object Value"
      assert conn.resp_body =~ "Process Model Graph"
      assert conn.resp_body =~ "Schema Introspection"
      assert conn.resp_body =~ "getFlowNodeInstance"
      assert conn.resp_body =~ "getProcessVersion"
      assert conn.resp_body =~ "getDecisionDefinition"
      assert conn.resp_body =~ "decisionVersions"
      assert conn.resp_body =~ "getDataObjectValue"
      assert conn.resp_body =~ "processModel"
      assert conn.resp_body =~ "dataObjectValues"
      assert conn.resp_body =~ "dataObjectHistory"
      assert conn.resp_body =~ "decisionDefinitions"
    end

    test "HTML contains auth bar elements" do
      conn = conn(:get, "/admin/graphiql") |> call()

      assert conn.resp_body =~ "id=\"auth-bar\""
      assert conn.resp_body =~ "id=\"token-input\""
      assert conn.resp_body =~ "applyToken()"
      assert conn.resp_body =~ "evil_playground_token"
    end

    test "HTML contains fetch interceptor for auth injection" do
      conn = conn(:get, "/admin/graphiql") |> call()

      assert conn.resp_body =~ "window.fetch"
      assert conn.resp_body =~ "Authorization"
    end

    test "HTML contains valid JSON tab configuration" do
      conn = conn(:get, "/admin/graphiql") |> call()

      assert conn.resp_body =~ "GraphQLPlayground.init"
      assert conn.resp_body =~ "schema.polling.enable"
    end
  end

  describe "GET /admin/graphiql with devtools disabled" do
    test "returns 404" do
      Application.put_env(:api_web, :devtools_enabled, false)

      conn = conn(:get, "/admin/graphiql") |> call()

      assert conn.status == 404
      assert conn.resp_body == "Not Found"
    end
  end

  defp has_content_type?(conn, expected) do
    Enum.any?(conn.resp_headers, fn
      {"content-type", ct} -> ct =~ expected
      _ -> false
    end)
  end
end
