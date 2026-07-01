defmodule EvilEngine.Integration.HealthInfoStatsTest do
  @moduledoc "Full-stack: public probes and authenticated telemetry."
  use EvilEngine.IntegrationCase, async: false

  # --- /health (public, no auth) -----------------------------------------

  describe "GET /health" do
    test "returns 204 with no body" do
      conn = conn(:get, "/health") |> route()

      assert conn.status == 204
      assert conn.resp_body == ""
    end

    test "works with garbage Authorization header" do
      conn =
        conn(:get, "/health")
        |> put_req_header("authorization", "garbage")
        |> route()

      assert conn.status == 204
    end

    test "works with random query params" do
      conn = conn(:get, "/health?foo=bar&xss=<script>") |> route()
      assert conn.status == 204
    end
  end

  # --- / (root, Swagger UI) ------------------------------------------------

  describe "GET /" do
    test "returns Swagger UI HTML" do
      conn = conn(:get, "/") |> route()
      assert conn.status == 200
      assert conn.resp_body =~ "swagger"
    end
  end

  # --- /info (public, no auth) -------------------------------------------

  describe "GET /info" do
    test "returns 200 with engine identity" do
      conn = conn(:get, "/info") |> route()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert is_binary(body["engineId"])
      assert is_binary(body["engineName"])
      assert is_binary(body["version"])
      assert is_binary(body["startedAt"])
    end
  end

  # --- /stats (authenticated) -------------------------------------------

  describe "GET /stats" do
    test "rejects unauthenticated request" do
      with_config(:api_auth, :auth_disabled, false, fn ->
        conn = conn(:get, "/stats") |> route()

        assert conn.status == 401
        body = Jason.decode!(conn.resp_body)
        assert body["error"] == "unauthorized"
      end)
    end

    test "returns full snapshot with valid JWT" do
      with_config(:api_auth, :auth_disabled, false, fn ->
        conn =
          conn_with_auth(:get, "/stats", %{"sub" => "operator-1", "roles" => ["admin"]})
          |> route()

        assert conn.status == 200
        body = Jason.decode!(conn.resp_body)
        assert is_map(body["engine"])
        assert is_map(body["processInstances"])
        assert is_map(body["listeners"])
      end)
    end

    test "rejects expired JWT" do
      with_config(:api_auth, :auth_disabled, false, fn ->
        token =
          sign_jwt(%{
            "sub" => "expired-user",
            "exp" => DateTime.utc_now() |> DateTime.add(-3600) |> DateTime.to_unix()
          })

        conn =
          conn(:get, "/stats")
          |> put_req_header("authorization", "Bearer #{token}")
          |> route()

        assert conn.status == 401
        body = Jason.decode!(conn.resp_body)
        assert body["error"] == "unauthorized"
        assert body["message"] == "Authentication required"
      end)
    end

    test "rejects wrong-secret JWT" do
      with_config(:api_auth, :auth_disabled, false, fn ->
        wrong_jwk = JOSE.JWK.from_oct("completely_wrong_secret_32_bytes_!")
        claims = %{"sub" => "intruder", "exp" => DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_unix()}
        {_, token} = JOSE.JWT.sign(wrong_jwk, %{"alg" => "HS256"}, claims) |> JOSE.JWS.compact()

        conn =
          conn(:get, "/stats")
          |> put_req_header("authorization", "Bearer #{token}")
          |> route()

        assert conn.status == 401
      end)
    end

    test "passes through with auth disabled" do
      with_config(:api_auth, :auth_disabled, true, fn ->
        conn = conn(:get, "/stats") |> route()
        assert conn.status == 200
      end)
    end
  end

  # --- routing edge cases ------------------------------------------------

  describe "routing" do
    test "POST to GET-only endpoint returns 404" do
      result = conn(:post, "/health") |> route()
      assert result.status == 404
    end

    test "unknown route returns 404" do
      result = conn(:get, "/nonexistent") |> route()
      assert result.status == 404
    end

    test "very long path is handled gracefully" do
      result = conn(:get, "/" <> String.duplicate("a", 2000)) |> route()
      assert result.status == 404
    end
  end
end
