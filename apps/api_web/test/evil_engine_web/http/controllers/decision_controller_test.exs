defmodule EvilEngineWeb.Http.DecisionControllerTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias Ecto.Adapters.SQL.Sandbox
  alias EvilEngine.Api
  alias EvilEngine.Auth.ProviderRegistry
  alias EvilEngine.DMN
  alias EvilEngine.DMN.ModelCache, as: DMNModelCache
  alias EvilEngine.Execution.DecisionResolver
  alias EvilEngine.Persistence.ReadRepo
  alias EvilEngine.Persistence.Repo

  @endpoint EvilEngineWeb.Http.Endpoint
  @test_secret "test_only_secret_at_least_32_bytes!"

  setup do
    ProviderRegistry.reset_to_default()

    try do
      :ok = Sandbox.checkout(Repo)
      Sandbox.mode(Repo, {:shared, self()})
      :ok = Sandbox.checkout(ReadRepo)
      Sandbox.mode(ReadRepo, {:shared, self()})
    rescue
      _ -> :ok
    end

    on_exit(fn -> ProviderRegistry.reset_to_default() end)
    :ok
  end

  defp call(conn), do: @endpoint.call(conn, @endpoint.init([]))

  defp sign_jwt(claims) do
    Application.put_env(:api_auth, :hs256_secret, @test_secret)
    jwk = JOSE.JWK.from_oct(@test_secret)

    defaults = %{
      "sub" => "test-user",
      "exp" => DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_unix(),
      "iat" => DateTime.utc_now() |> DateTime.to_unix()
    }

    merged = Map.merge(defaults, claims)
    {_, token} = JOSE.JWT.sign(jwk, %{"alg" => "HS256"}, merged) |> JOSE.JWS.compact()
    token
  end

  defp deploy_dmn_conn(body, claims \\ %{"deploy_dmn" => true}) do
    json_body = Jason.encode!(body)

    conn(:post, "/decisions", json_body)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Plug.Conn.put_req_header("authorization", "Bearer #{sign_jwt(claims)}")
    |> call()
  end

  defp auth_conn(method, path, claims) do
    auth_conn(method, path, claims, %{})
  end

  defp auth_conn(method, path, claims, body) do
    request_body = Jason.encode!(body)

    conn(method, path, request_body)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Plug.Conn.put_req_header("authorization", "Bearer #{sign_jwt(claims)}")
    |> call()
  end

  defp with_auth_enabled(fun) do
    previous = Application.get_env(:api_auth, :auth_disabled)
    Application.delete_env(:api_auth, :auth_disabled)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:api_auth, :auth_disabled)
        value -> Application.put_env(:api_auth, :auth_disabled, value)
      end
    end)

    fun.()
  end

  defp assert_error_body(body, expected_error) do
    assert is_binary(body["message"])
    assert body["error"] == expected_error
    refute body["message"] =~ "%{"
    refute body["message"] =~ "#PID<"
  end

  @dmn_fixtures_dir Path.expand("../../../../../../test/fixtures/dmns", __DIR__)

  defp read_dmn_fixture(filename) do
    File.read!(Path.join(@dmn_fixtures_dir, filename))
  end

  defp wire_decision_resolver_for_model(decision_definition_id) do
    {:ok, definition} = Api.get_decision_by_model_id(decision_definition_id)
    {:ok, version} = Api.get_latest_decision_version(definition.id)

    DecisionResolver.NoOp.set_version(
      decision_definition_id,
      version.id
    )
  end

  defp ensure_dmn_deployed(dmn_xml) do
    case deploy_dmn_conn(%{"sources" => [dmn_xml]}) do
      %{status: 201} = response -> {:ok, response}
      %{status: 409} = response -> {:already_deployed, response}
      response -> {:error, response.status}
    end
  end

  defp ensure_dmn_model_cached(decision_definition_id) do
    {:ok, definition} = Api.get_decision_by_model_id(decision_definition_id)
    {:ok, version} = Api.get_latest_decision_version(definition.id)

    case DMNModelCache.fetch(version.id) do
      {:ok, _definitions} ->
        :ok

      {:error, :not_found} ->
        {:ok, definitions} = DMN.parse_and_validate(version.dmn_xml)
        DMNModelCache.put_new(version.id, definitions)
    end
  end

  describe "decision catalog routes" do
    setup do
      previous = Application.get_env(:api_auth, :auth_disabled)
      Application.put_env(:api_auth, :auth_disabled, true)

      on_exit(fn ->
        case previous do
          nil -> Application.delete_env(:api_auth, :auth_disabled)
          value -> Application.put_env(:api_auth, :auth_disabled, value)
        end
      end)

      :ok
    end

    test "GET /decisions returns empty list when nothing deployed" do
      conn = conn(:get, "/decisions") |> call()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert is_list(body)
    end

    test "GET /decisions/:model_id returns 404 for non-existent model id" do
      conn =
        conn(
          :get,
          "/decisions/nonexistent-decision-#{System.unique_integer([:positive])}"
        )
        |> call()

      assert conn.status == 404
      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "decision_definition_not_found"
    end

    test "GET /decisions/:model_id/versions returns 404 for non-existent model id" do
      conn =
        conn(
          :get,
          "/decisions/nonexistent-decision-#{System.unique_integer([:positive])}/versions"
        )
        |> call()

      assert conn.status == 404
      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "decision_definition_not_found"
    end

    test "PUT /decisions/:model_id/enable returns 403 in auth-disabled mode (no deploy_dmn)" do
      dmn_xml = read_dmn_fixture("simple_unique.dmn")

      Application.put_env(:api_auth, :auth_disabled, false)
      deploy_dmn_conn(%{"sources" => [dmn_xml]})
      Application.put_env(:api_auth, :auth_disabled, true)

      conn =
        conn(:put, "/decisions/definitions_discount/enable")
        |> call()

      assert conn.status == 403
      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "forbidden"
    end

    test "PUT /decisions/:model_id/disable returns 403 in auth-disabled mode (no deploy_dmn)" do
      dmn_xml = read_dmn_fixture("simple_unique.dmn")

      Application.put_env(:api_auth, :auth_disabled, false)
      deploy_dmn_conn(%{"sources" => [dmn_xml]})
      Application.put_env(:api_auth, :auth_disabled, true)

      conn =
        conn(:put, "/decisions/definitions_discount/disable")
        |> call()

      assert conn.status == 403
      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "forbidden"
    end
  end

  describe "deploy error paths" do
    setup do
      previous = Application.get_env(:api_auth, :auth_disabled)
      Application.delete_env(:api_auth, :auth_disabled)

      on_exit(fn ->
        case previous do
          nil -> Application.delete_env(:api_auth, :auth_disabled)
          value -> Application.put_env(:api_auth, :auth_disabled, value)
        end
      end)

      :ok
    end

    test "returns 400 for missing sources key" do
      conn = deploy_dmn_conn(%{})

      assert conn.status == 400
      body = Jason.decode!(conn.resp_body)
      assert_error_body(body, "bad_request")
      assert body["message"] =~ "sources"
    end

    test "returns 400 for empty sources array" do
      conn = deploy_dmn_conn(%{"sources" => []})

      assert conn.status == 400
      body = Jason.decode!(conn.resp_body)
      assert_error_body(body, "bad_request")
    end

    test "returns 400 for invalid DMN XML" do
      conn = deploy_dmn_conn(%{"sources" => ["this is not valid DMN XML"]})

      assert conn.status == 400
      body = Jason.decode!(conn.resp_body)
      assert_error_body(body, "dmn_parse_error")
    end

    test "returns 403 without deploy_dmn claim" do
      conn = deploy_dmn_conn(%{"sources" => ["<xml/>"]}, %{})

      assert conn.status == 403
      body = Jason.decode!(conn.resp_body)
      assert_error_body(body, "forbidden")
      assert body["requiredClaim"] == "deploy_dmn"
      assert body["resource"] == "decision"
    end

    test "admin override bypasses deploy_dmn claim check (gets past 403)" do
      conn =
        deploy_dmn_conn(
          %{"sources" => ["this is not XML at all"]},
          %{"deploy_dmn" => false, "zeeky_boogie_doog" => true}
        )

      refute conn.status == 403
      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "dmn_parse_error"
    end
  end

  describe "evaluate error paths" do
    setup do
      previous = Application.get_env(:api_auth, :auth_disabled)
      Application.put_env(:api_auth, :auth_disabled, true)

      on_exit(fn ->
        case previous do
          nil -> Application.delete_env(:api_auth, :auth_disabled)
          value -> Application.put_env(:api_auth, :auth_disabled, value)
        end
      end)

      :ok
    end

    test "returns 404 for non-existent decision model" do
      conn =
        auth_conn(
          :post,
          "/decisions/nonexistent-#{System.unique_integer([:positive])}/evaluate",
          %{},
          %{"input" => %{"value" => 5}}
        )

      assert conn.status == 404
      body = Jason.decode!(conn.resp_body)
      assert_error_body(body, "decision_definition_not_found")
    end

    test "returns 404 for evaluate_version with non-existent version" do
      with_auth_enabled(fn ->
        dmn_xml = read_dmn_fixture("simple_unique.dmn")

        case ensure_dmn_deployed(dmn_xml) do
          {:ok, _} -> :ok
          {:already_deployed, _} -> :ok
          {:error, status} -> flunk("unexpected deploy status #{status}")
        end

        conn =
          auth_conn(
            :post,
            "/decisions/definitions_discount/versions/9.9.9-nonexistent/evaluate",
            %{"deploy_dmn" => true},
            %{"input" => %{"age" => 25}}
          )

        assert conn.status == 404
        body = Jason.decode!(conn.resp_body)
        assert_error_body(body, "no_active_version")
      end)
    end

    test "returns 404 for evaluate_service with non-existent service" do
      with_auth_enabled(fn ->
        dmn_xml = read_dmn_fixture("decision_service_basic.dmn")

        case ensure_dmn_deployed(dmn_xml) do
          {:ok, _} -> :ok
          {:already_deployed, _} -> :ok
          {:error, status} -> flunk("unexpected deploy status #{status}")
        end

        wire_decision_resolver_for_model("Definitions_ds_basic")
        :ok = ensure_dmn_model_cached("Definitions_ds_basic")

        conn =
          auth_conn(
            :post,
            "/decisions/Definitions_ds_basic/services/NonExistentService/evaluate",
            %{"deploy_dmn" => true},
            %{"input" => %{"Age" => 30, "Income" => 50_000}}
          )

        assert conn.status == 404
        body = Jason.decode!(conn.resp_body)
        assert_error_body(body, "service_not_found")
      end)
    end
  end

  describe "management actions" do
    test "enable returns 404 for non-existent model" do
      with_auth_enabled(fn ->
        model_id = "nonexistent-decision-#{System.unique_integer([:positive])}"

        conn = auth_conn(:put, "/decisions/#{model_id}/enable", %{"deploy_dmn" => true})

        assert conn.status == 404
        body = Jason.decode!(conn.resp_body)
        assert_error_body(body, "not_found")
      end)
    end

    test "disable returns 404 for non-existent model" do
      with_auth_enabled(fn ->
        model_id = "nonexistent-decision-#{System.unique_integer([:positive])}"

        conn = auth_conn(:put, "/decisions/#{model_id}/disable", %{"deploy_dmn" => true})

        assert conn.status == 404
        body = Jason.decode!(conn.resp_body)
        assert_error_body(body, "not_found")
      end)
    end

    test "delete_version returns 404 for non-existent model" do
      with_auth_enabled(fn ->
        model_id = "nonexistent-decision-#{System.unique_integer([:positive])}"

        conn =
          auth_conn(:delete, "/decisions/#{model_id}/versions/1.0.0", %{
            "delete_dmn" => true
          })

        assert conn.status == 404
        body = Jason.decode!(conn.resp_body)
        assert_error_body(body, "not_found")
      end)
    end

    test "undeploy returns 404 for non-existent model" do
      with_auth_enabled(fn ->
        model_id = "nonexistent-decision-#{System.unique_integer([:positive])}"

        conn = auth_conn(:delete, "/decisions/#{model_id}", %{"delete_dmn" => true})

        assert conn.status == 404
        body = Jason.decode!(conn.resp_body)
        assert_error_body(body, "not_found")
      end)
    end
  end

  describe "DELETE /decisions — authorization" do
    setup do
      previous = Application.get_env(:api_auth, :auth_disabled)
      Application.delete_env(:api_auth, :auth_disabled)

      on_exit(fn ->
        case previous do
          nil -> Application.delete_env(:api_auth, :auth_disabled)
          value -> Application.put_env(:api_auth, :auth_disabled, value)
        end
      end)

      :ok
    end

    test "DELETE /decisions/:model_id returns 403 without delete_dmn claim" do
      model_id = "auth_delete_decision_#{System.unique_integer([:positive])}"

      dmn_xml =
        read_dmn_fixture("simple_unique.dmn")
        |> String.replace("definitions_discount", model_id)

      assert match?({:ok, _response}, ensure_dmn_deployed(dmn_xml))

      conn =
        conn(:delete, "/decisions/#{model_id}", "")
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("authorization", "Bearer #{sign_jwt(%{})}")
        |> call()

      assert conn.status == 403
      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "forbidden"
      assert body["requiredClaim"] == "delete_dmn"
      assert body["resource"] == "decision"
    end

    test "DELETE /decisions/:model_id/versions/:version returns 403 without delete_dmn claim" do
      dmn_xml = read_dmn_fixture("simple_unique.dmn")

      deployed_version =
        with_auth_enabled(fn ->
          case ensure_dmn_deployed(dmn_xml) do
            {:ok, response} ->
              Jason.decode!(response.resp_body)["deployed"]
              |> List.first()
              |> Map.fetch!("version")

            {:already_deployed, _response} ->
              {:ok, definition} = Api.get_decision_by_model_id("definitions_discount")
              {:ok, version} = Api.get_latest_decision_version(definition.id)
              version.version
          end
        end)

      conn =
        conn(:delete, "/decisions/definitions_discount/versions/#{deployed_version}", "")
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("authorization", "Bearer #{sign_jwt(%{})}")
        |> call()

      assert conn.status == 403
      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "forbidden"
      assert body["requiredClaim"] == "delete_dmn"
    end
  end
end
