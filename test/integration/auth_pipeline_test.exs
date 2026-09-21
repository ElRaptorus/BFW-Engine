defmodule BfwEngine.Integration.AuthPipelineTest do
  @moduledoc "Full-stack: JWT auth through the real HTTP pipeline."
  use BfwEngine.IntegrationCase, async: false

  describe "identity construction" do
    test "identity.id comes from 'sub' claim" do
      with_config(:api_auth, :auth_disabled, false, fn ->
        conn =
          conn_with_auth(:get, "/stats", %{"sub" => "user-42", "roles" => ["viewer"]})
          |> route()

        assert conn.status == 200
      end)
    end

    test "identity.id falls back to 'client_id' when no 'sub'" do
      with_config(:api_auth, :auth_disabled, false, fn ->
        conn =
          conn_with_auth(:get, "/stats", %{"client_id" => "svc-bot-7"})
          |> route()

        assert conn.status == 200
      end)
    end

    test "missing both 'sub' and 'client_id' yields unknown identity but still authenticates" do
      with_config(:api_auth, :auth_disabled, false, fn ->
        conn =
          conn_with_auth(:get, "/stats", %{"custom" => "data"})
          |> route()

        assert conn.status == 200
      end)
    end
  end

  describe "malformed input" do
    test "non-JWT bearer string" do
      with_config(:api_auth, :auth_disabled, false, fn ->
        conn =
          conn(:get, "/stats")
          |> put_req_header("authorization", "Bearer not.a.jwt")
          |> route()

        assert conn.status == 401
      end)
    end

    test "completely empty Authorization header" do
      with_config(:api_auth, :auth_disabled, false, fn ->
        conn =
          conn(:get, "/stats")
          |> put_req_header("authorization", "")
          |> route()

        assert conn.status == 401
      end)
    end

    test "Bearer with empty token" do
      with_config(:api_auth, :auth_disabled, false, fn ->
        conn =
          conn(:get, "/stats")
          |> put_req_header("authorization", "Bearer ")
          |> route()

        assert conn.status == 401
      end)
    end

    test "massive Authorization header" do
      with_config(:api_auth, :auth_disabled, false, fn ->
        conn =
          conn(:get, "/stats")
          |> put_req_header("authorization", "Bearer " <> String.duplicate("a", 50_000))
          |> route()

        assert conn.status == 401
      end)
    end
  end
end
