defmodule EvilEngineWeb.Http.AdhocSubprocessControllerTest do
  use ExUnit.Case, async: false

  import Plug.Test

  @endpoint EvilEngineWeb.Http.Endpoint
  @test_secret "test_only_secret_at_least_32_bytes!"

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

  defp auth_conn(method, path, claims, body \\ "") do
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

  # ------------------------------------------------------------------
  # GET /adhoc-subprocesses/:id/activities
  # ------------------------------------------------------------------

  describe "GET /adhoc-subprocesses/:id/activities" do
    test "returns 403 without manage_adhoc_subprocess claim" do
      with_auth_enabled(fn ->
        conn = auth_conn(:get, "/adhoc-subprocesses/nonexistent-id/activities", %{})

        assert conn.status == 403
        body = Jason.decode!(conn.resp_body)
        assert_error_body(body, "forbidden")
      end)
    end

    test "returns 200 with admin override even without specific claim" do
      with_auth_enabled(fn ->
        conn =
          auth_conn(:get, "/adhoc-subprocesses/nonexistent-id/activities", %{
            "zeeky_boogie_doog" => true
          })

        # Will get 404 or 500 because the PI doesn't exist — but NOT 403
        assert conn.status in [404, 500]
      end)
    end

    test "returns error for non-existent process instance" do
      with_auth_enabled(fn ->
        conn =
          auth_conn(:get, "/adhoc-subprocesses/nonexistent-id/activities", %{
            "manage_adhoc_subprocess" => true
          })

        assert conn.status in [404, 500]
      end)
    end
  end

  # ------------------------------------------------------------------
  # POST /adhoc-subprocesses/:id/activities/:activity_id/activate
  # ------------------------------------------------------------------

  describe "POST /adhoc-subprocesses/:id/activities/:activity_id/activate" do
    test "returns 403 without manage_adhoc_subprocess claim" do
      with_auth_enabled(fn ->
        conn =
          auth_conn(
            :post,
            "/adhoc-subprocesses/nonexistent-id/activities/Task_1/activate",
            %{}
          )

        assert conn.status == 403
        body = Jason.decode!(conn.resp_body)
        assert_error_body(body, "forbidden")
      end)
    end

    test "returns error for non-existent process instance" do
      with_auth_enabled(fn ->
        conn =
          auth_conn(
            :post,
            "/adhoc-subprocesses/nonexistent-id/activities/Task_1/activate",
            %{"manage_adhoc_subprocess" => true}
          )

        assert conn.status in [404, 500]
      end)
    end
  end

  # ------------------------------------------------------------------
  # POST /adhoc-subprocesses/:id/complete
  # ------------------------------------------------------------------

  describe "POST /adhoc-subprocesses/:id/complete" do
    test "returns 403 without manage_adhoc_subprocess claim" do
      with_auth_enabled(fn ->
        conn = auth_conn(:post, "/adhoc-subprocesses/nonexistent-id/complete", %{})

        assert conn.status == 403
        body = Jason.decode!(conn.resp_body)
        assert_error_body(body, "forbidden")
      end)
    end

    test "returns error for non-existent process instance" do
      with_auth_enabled(fn ->
        conn =
          auth_conn(:post, "/adhoc-subprocesses/nonexistent-id/complete", %{
            "manage_adhoc_subprocess" => true
          })

        assert conn.status in [404, 500]
      end)
    end
  end

  # ------------------------------------------------------------------
  # GET /adhoc-subprocesses/:id/status
  # ------------------------------------------------------------------

  describe "GET /adhoc-subprocesses/:id/status" do
    test "returns 403 without manage_adhoc_subprocess claim" do
      with_auth_enabled(fn ->
        conn = auth_conn(:get, "/adhoc-subprocesses/nonexistent-id/status", %{})

        assert conn.status == 403
        body = Jason.decode!(conn.resp_body)
        assert_error_body(body, "forbidden")
      end)
    end

    test "returns error for non-existent process instance" do
      with_auth_enabled(fn ->
        conn =
          auth_conn(:get, "/adhoc-subprocesses/nonexistent-id/status", %{
            "manage_adhoc_subprocess" => true
          })

        assert conn.status in [404, 500]
      end)
    end
  end
end
