defmodule EvilEngineWeb.Http.EscalationControllerTest do
  @moduledoc """
  HTTP + claim tests for `POST /escalations/:escalation_code/trigger`.
  """

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

  defp auth_conn(method, path, claims, body \\ "{}") do
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

  describe "POST /escalations/:escalation_code/trigger" do
    test "returns 403 without trigger_escalation claim" do
      with_auth_enabled(fn ->
        conn = auth_conn(:post, "/escalations/ESC_API/trigger", %{})

        assert conn.status == 403
        body = Jason.decode!(conn.resp_body)
        assert body["error"] == "forbidden"
      end)
    end

    test "returns 200 with trigger_escalation claim and no waiters" do
      with_auth_enabled(fn ->
        conn =
          auth_conn(:post, "/escalations/NO_WAITERS/trigger", %{
            "trigger_escalation" => true
          })

        assert conn.status == 200
        body = Jason.decode!(conn.resp_body)
        assert body["escalationCode"] == "NO_WAITERS"
        assert body["deliveries"] == []
        assert body["pending"] == false
      end)
    end

    test "returns 200 with zeeky_boogie_doog even without trigger_escalation" do
      with_auth_enabled(fn ->
        conn =
          auth_conn(:post, "/escalations/NO_WAITERS/trigger", %{
            "zeeky_boogie_doog" => true
          })

        assert conn.status == 200
        body = Jason.decode!(conn.resp_body)
        assert body["deliveries"] == []
        assert body["pending"] == false
      end)
    end

    test "returns 422 for a blank escalation code" do
      with_auth_enabled(fn ->
        conn =
          auth_conn(:post, "/escalations/%20/trigger", %{
            "trigger_escalation" => true
          })

        assert conn.status == 422
        body = Jason.decode!(conn.resp_body)
        assert body["error"] == "escalation_code_blank"
      end)
    end

    test "returns 422 for an oversize escalation code" do
      with_auth_enabled(fn ->
        oversize_code = String.duplicate("A", 257)

        conn =
          auth_conn(:post, "/escalations/#{oversize_code}/trigger", %{
            "trigger_escalation" => true
          })

        assert conn.status == 422
        body = Jason.decode!(conn.resp_body)
        assert body["error"] == "escalation_code_too_long"
      end)
    end
  end
end
