defmodule EvilEngineWeb.Http.ProcessControllerTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias Ecto.Adapters.SQL.Sandbox
  alias EvilEngine.Api
  alias EvilEngine.Auth.ProviderRegistry
  alias EvilEngine.BPMN
  alias EvilEngine.BPMN.ModelCache, as: BPMNModelCache
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

  defp deploy_conn(body, claims \\ %{"deploy_bpmn" => true}) do
    json_body = Jason.encode!(body)

    conn(:post, "/processes", json_body)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Plug.Conn.put_req_header("authorization", "Bearer #{sign_jwt(claims)}")
    |> call()
  end

  defp auth_conn(method, path, claims) do
    auth_conn(method, path, claims, "")
  end

  defp auth_conn(method, path, claims, body) when is_map(body) do
    request_body = Jason.encode!(body)

    conn(method, path, request_body)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Plug.Conn.put_req_header("authorization", "Bearer #{sign_jwt(claims)}")
    |> call()
  end

  defp auth_conn(method, path, claims, body) do
    conn(method, path, body)
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

  @bpmn_fixtures_dir Path.expand("../../../../../../test/fixtures/bpmns", __DIR__)

  defp read_bpmn_fixture(filename) do
    File.read!(Path.join(@bpmn_fixtures_dir, filename))
  end

  defp ensure_bpmn_deployed(bpmn_xml) do
    case deploy_conn(%{"sources" => [bpmn_xml]}) do
      %{status: 201} = response -> {:ok, response}
      %{status: 409} -> :already_deployed
      response -> {:error, response.status}
    end
  end

  defp ensure_bpmn_model_cached(process_model_id) do
    {:ok, process} = Api.get_process_by_model_id(process_model_id)
    {:ok, version} = Api.get_latest_process_version(process.id)

    case BPMNModelCache.fetch(version.id) do
      {:ok, _definitions} ->
        :ok

      {:error, :not_found} ->
        {:ok, definitions} = BPMN.parse_and_validate(version.bpmn_xml)
        BPMNModelCache.put_new(version.id, definitions)
    end
  end

  describe "process catalog routes" do
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

    test "GET /processes/:model_id returns 404 for non-existent model id" do
      conn =
        conn(
          :get,
          "/processes/nonexistent-process-model-id-#{System.unique_integer([:positive])}"
        )
        |> call()

      assert conn.status == 404
      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "not_found"
    end

    test "PUT /processes/:model_id/enable returns 403 in auth-disabled mode (no deploy_bpmn)" do
      bpmn_xml = read_bpmn_fixture("linear_start_end.bpmn")

      Application.put_env(:api_auth, :auth_disabled, false)
      deploy_conn(%{"sources" => [bpmn_xml]})
      Application.put_env(:api_auth, :auth_disabled, true)

      conn =
        conn(:put, "/processes/LinearStartEnd/enable")
        |> call()

      assert conn.status == 403
      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "forbidden"
    end

    test "PUT /processes/:model_id/disable returns 403 in auth-disabled mode (no deploy_bpmn)" do
      bpmn_xml = read_bpmn_fixture("linear_start_end.bpmn")

      Application.put_env(:api_auth, :auth_disabled, false)
      deploy_conn(%{"sources" => [bpmn_xml]})
      Application.put_env(:api_auth, :auth_disabled, true)

      conn =
        conn(:put, "/processes/LinearStartEnd/disable")
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

    test "returns 400 for empty sources array" do
      conn = deploy_conn(%{"sources" => []})

      assert conn.status == 400
      body = Jason.decode!(conn.resp_body)
      assert_error_body(body, "bad_request")
    end

    test "returns 400 for missing sources key" do
      conn = deploy_conn(%{})

      assert conn.status == 400
      body = Jason.decode!(conn.resp_body)
      assert_error_body(body, "bad_request")
      assert body["message"] =~ "sources"
    end

    test "returns 400 for non-XML source string" do
      conn = deploy_conn(%{"sources" => ["not xml"]})

      assert conn.status == 400
      body = Jason.decode!(conn.resp_body)
      assert_error_body(body, "parse_error")
    end

    test "returns 400 with diagnostic message for broken XML" do
      conn = deploy_conn(%{"sources" => ["<bpmn:definitions><unclosed>"]})

      assert conn.status == 400
      body = Jason.decode!(conn.resp_body)
      assert_error_body(body, "parse_error")
      assert body["message"] =~ "parsing"
    end

    test "returns 403 without deploy_bpmn claim" do
      conn = deploy_conn(%{"sources" => ["<xml/>"]}, %{})

      assert conn.status == 403
      body = Jason.decode!(conn.resp_body)
      assert_error_body(body, "forbidden")
      assert body["message"] =~ "permissions"
    end

    test "rejects old application/bpmn+xml content type" do
      assert_raise Plug.Parsers.UnsupportedMediaTypeError, fn ->
        conn(:post, "/processes", "<not-bpmn/>")
        |> Plug.Conn.put_req_header("content-type", "application/bpmn+xml")
        |> Plug.Conn.put_req_header(
          "authorization",
          "Bearer #{sign_jwt(%{"deploy_bpmn" => true})}"
        )
        |> call()
      end
    end
  end

  describe "start error paths" do
    test "returns 404 for non-existent process model" do
      with_auth_enabled(fn ->
        model_id = "nonexistent-process-#{System.unique_integer([:positive])}"

        conn =
          auth_conn(:post, "/processes/#{model_id}/start", %{"deploy_bpmn" => true}, %{
            "payload" => %{}
          })

        assert conn.status == 404
        body = Jason.decode!(conn.resp_body)
        assert_error_body(body, "process_not_found")
      end)
    end

    test "returns 404 without lane claim required to start process (lane denial hides existence)" do
      with_auth_enabled(fn ->
        bpmn_xml = read_bpmn_fixture("linear_start_end.bpmn")

        case ensure_bpmn_deployed(bpmn_xml) do
          {:ok, _} -> :ok
          :already_deployed -> :ok
          {:error, status} -> flunk("unexpected deploy status #{status}")
        end

        :ok = ensure_bpmn_model_cached("LinearStartEnd")

        conn =
          auth_conn(:post, "/processes/LinearStartEnd/start", %{}, %{"payload" => %{}})

        assert conn.status == 404
        body = Jason.decode!(conn.resp_body)
        assert_error_body(body, "not_found")
      end)
    end
  end

  describe "version management" do
    test "returns 404 for versions of non-existent model" do
      previous = Application.get_env(:api_auth, :auth_disabled)
      Application.put_env(:api_auth, :auth_disabled, true)

      on_exit(fn ->
        case previous do
          nil -> Application.delete_env(:api_auth, :auth_disabled)
          value -> Application.put_env(:api_auth, :auth_disabled, value)
        end
      end)

      model_id = "nonexistent-process-#{System.unique_integer([:positive])}"

      conn = conn(:get, "/processes/#{model_id}/versions") |> call()

      assert conn.status == 404
      body = Jason.decode!(conn.resp_body)
      assert_error_body(body, "not_found")
    end

    test "returns 404 for enable of non-existent model" do
      with_auth_enabled(fn ->
        model_id = "nonexistent-process-#{System.unique_integer([:positive])}"

        conn =
          auth_conn(:put, "/processes/#{model_id}/enable", %{"deploy_bpmn" => true})

        assert conn.status == 404
        body = Jason.decode!(conn.resp_body)
        assert_error_body(body, "not_found")
      end)
    end

    test "returns 404 for disable of non-existent model" do
      with_auth_enabled(fn ->
        model_id = "nonexistent-process-#{System.unique_integer([:positive])}"

        conn =
          auth_conn(:put, "/processes/#{model_id}/disable", %{"deploy_bpmn" => true})

        assert conn.status == 404
        body = Jason.decode!(conn.resp_body)
        assert_error_body(body, "not_found")
      end)
    end
  end
end
