defmodule BfwEngine.Auth.PlugTest do
  use ExUnit.Case, async: false

  alias BfwEngine.Auth.Plug, as: AuthPlug
  alias BfwEngine.Auth.ProviderRegistry
  alias BfwEngine.Test.AuthHelper
  alias BfwEngine.Types.Identity

  setup do
    ProviderRegistry.reset_to_default()
    :ok
  end

  defp call_plug(conn) do
    opts = AuthPlug.init([])
    AuthPlug.call(conn, opts)
  end

  describe "auth disabled mode" do
    test "assigns anonymous identity" do
      AuthHelper.with_auth_disabled(fn ->
        conn = Plug.Test.conn(:get, "/stats") |> call_plug()

        refute conn.halted
        assert %Identity{id: "anonymous"} = conn.assigns.identity
        assert conn.assigns.auth_method == :anonymous
      end)
    end

    test "anonymous identity has empty roles and groups" do
      AuthHelper.with_auth_disabled(fn ->
        conn = Plug.Test.conn(:get, "/anything") |> call_plug()

        assert conn.assigns.identity.roles == []
        assert conn.assigns.identity.groups == []
        assert conn.assigns.identity.claims == %{}
      end)
    end
  end

  describe "auth enabled - missing header" do
    test "returns 401 when no Authorization header" do
      AuthHelper.with_auth_enabled(fn ->
        conn = Plug.Test.conn(:get, "/stats") |> call_plug()

        assert conn.halted
        assert conn.status == 401
        body = Jason.decode!(conn.resp_body)
        assert body["error"] == "unauthorized"
        assert body["message"] =~ "Missing Authorization"
      end)
    end

    test "returns 401 with wrong header format" do
      AuthHelper.with_auth_enabled(fn ->
        conn =
          Plug.Test.conn(:get, "/stats")
          |> Plug.Conn.put_req_header("authorization", "Basic dXNlcjpwYXNz")
          |> call_plug()

        assert conn.halted
        assert conn.status == 401
      end)
    end

    test "returns 401 with empty Bearer token" do
      AuthHelper.with_auth_enabled(fn ->
        conn =
          Plug.Test.conn(:get, "/stats")
          |> Plug.Conn.put_req_header("authorization", "Bearer ")
          |> call_plug()

        assert conn.halted
        assert conn.status == 401
      end)
    end
  end

  describe "auth enabled - valid JWT" do
    test "assigns identity from JWT claims" do
      AuthHelper.with_auth_enabled(fn ->
        conn =
          AuthHelper.conn_with_auth(:get, "/stats", %{
            "sub" => "user-42",
            "roles" => ["operator", "admin"],
            "groups" => ["engineering"]
          })
          |> call_plug()

        refute conn.halted
        assert conn.assigns.auth_method == :jwt
        assert %Identity{} = identity = conn.assigns.identity
        assert identity.id == "user-42"
        assert identity.roles == ["operator", "admin"]
        assert identity.groups == ["engineering"]
      end)
    end

    test "uses client_id as fallback when sub is missing" do
      AuthHelper.with_auth_enabled(fn ->
        conn =
          AuthHelper.conn_with_auth(:get, "/stats", %{
            "client_id" => "service-account-1"
          })
          |> call_plug()

        refute conn.halted
        assert conn.assigns.identity.id == "service-account-1"
      end)
    end

    test "uses 'unknown' when neither sub nor client_id present" do
      AuthHelper.with_auth_enabled(fn ->
        conn =
          AuthHelper.conn_with_auth(:get, "/stats", %{})
          |> call_plug()

        refute conn.halted
        assert conn.assigns.identity.id == "unknown"
      end)
    end
  end

  describe "auth enabled - invalid JWT" do
    test "returns 401 for expired token with generic message (no leak)" do
      AuthHelper.with_auth_enabled(fn ->
        token = AuthHelper.sign_expired_jwt()

        conn =
          Plug.Test.conn(:get, "/stats")
          |> Plug.Conn.put_req_header("authorization", "Bearer #{token}")
          |> call_plug()

        assert conn.halted
        assert conn.status == 401
        body = Jason.decode!(conn.resp_body)
        assert body["error"] == "unauthorized"
        assert body["message"] == "Authentication required"
      end)
    end

    test "reason is logged at warning level, not sent to client" do
      AuthHelper.with_auth_enabled(fn ->
        token = AuthHelper.sign_expired_jwt()
        prev_level = Logger.level()
        Logger.configure(level: :warning)

        log =
          ExUnit.CaptureLog.capture_log(fn ->
            Plug.Test.conn(:get, "/stats")
            |> Plug.Conn.put_req_header("authorization", "Bearer #{token}")
            |> call_plug()
          end)

        Logger.configure(level: prev_level)
        assert log =~ "Auth rejected: JWT verification failed"
      end)
    end

    test "returns 401 for wrong secret with generic message (no leak)" do
      AuthHelper.with_auth_enabled(fn ->
        token = AuthHelper.sign_wrong_secret_jwt()

        conn =
          Plug.Test.conn(:get, "/stats")
          |> Plug.Conn.put_req_header("authorization", "Bearer #{token}")
          |> call_plug()

        assert conn.halted
        assert conn.status == 401
        body = Jason.decode!(conn.resp_body)
        assert body["error"] == "unauthorized"
        assert body["message"] == "Authentication required"
      end)
    end
  end

  describe "auth enabled - no key material" do
    test "returns 503 when no key configured" do
      previous = Application.get_env(:api_auth, :hs256_secret)
      Application.put_env(:api_auth, :hs256_secret, nil)

      try do
        AuthHelper.with_auth_enabled(fn ->
          temp_secret = "temp_signing_secret_at_least_32_bytes!"
          jwk = JOSE.JWK.from_oct(temp_secret)

          claims = %{
            "sub" => "x",
            "exp" => DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_unix()
          }

          {_, token} = JOSE.JWT.sign(jwk, %{"alg" => "HS256"}, claims) |> JOSE.JWS.compact()

          conn =
            Plug.Test.conn(:get, "/stats")
            |> Plug.Conn.put_req_header("authorization", "Bearer #{token}")
            |> call_plug()

          assert conn.halted
          assert conn.status == 503
          body = Jason.decode!(conn.resp_body)
          assert body["message"] =~ "No JWT key material"
        end)
      after
        Application.put_env(:api_auth, :hs256_secret, previous)
      end
    end
  end
end
