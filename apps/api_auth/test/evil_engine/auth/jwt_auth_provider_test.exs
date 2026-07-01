defmodule EvilEngine.Auth.JwtAuthProviderTest do
  use ExUnit.Case, async: false

  alias EvilEngine.Auth.JwtAuthProvider
  alias EvilEngine.Test.AuthHelper
  alias EvilEngine.Types.Identity

  describe "verify_and_resolve/1" do
    test "returns {:ok, %Identity{}} for a valid JWT" do
      AuthHelper.with_auth_enabled(fn ->
        token =
          AuthHelper.sign_jwt(%{
            "sub" => "user-42",
            "roles" => ["operator", "admin"],
            "groups" => ["engineering"]
          })

        assert {:ok, %Identity{} = identity} = JwtAuthProvider.verify_and_resolve(token)
        assert identity.id == "user-42"
        assert identity.roles == ["operator", "admin"]
        assert identity.groups == ["engineering"]
        assert identity.claims["sub"] == "user-42"
      end)
    end

    test "returns {:error, :expired} for an expired JWT" do
      AuthHelper.with_auth_enabled(fn ->
        token = AuthHelper.sign_expired_jwt(%{"sub" => "user-1"})
        assert {:error, :expired} = JwtAuthProvider.verify_and_resolve(token)
      end)
    end

    test "returns {:error, :invalid_signature} for a wrong-secret JWT" do
      AuthHelper.with_auth_enabled(fn ->
        token = AuthHelper.sign_wrong_secret_jwt()
        assert {:error, :invalid_signature} = JwtAuthProvider.verify_and_resolve(token)
      end)
    end
  end

  describe "build_identity/1" do
    test "uses sub claim as identity id" do
      identity = JwtAuthProvider.build_identity(%{"sub" => "user-99"})
      assert identity.id == "user-99"
    end

    test "falls back to client_id when sub is absent" do
      identity = JwtAuthProvider.build_identity(%{"client_id" => "svc-1"})
      assert identity.id == "svc-1"
    end

    test "falls back to 'unknown' when neither sub nor client_id present" do
      identity = JwtAuthProvider.build_identity(%{"custom" => "data"})
      assert identity.id == "unknown"
    end

    test "extracts roles and groups as lists" do
      identity =
        JwtAuthProvider.build_identity(%{
          "sub" => "x",
          "roles" => ["a", "b"],
          "groups" => ["g1"]
        })

      assert identity.roles == ["a", "b"]
      assert identity.groups == ["g1"]
    end

    test "defaults roles and groups to empty lists when absent" do
      identity = JwtAuthProvider.build_identity(%{"sub" => "x"})
      assert identity.roles == []
      assert identity.groups == []
    end

    test "defaults roles and groups to empty lists when not a list" do
      identity =
        JwtAuthProvider.build_identity(%{
          "sub" => "x",
          "roles" => "single-string",
          "groups" => 42
        })

      assert identity.roles == []
      assert identity.groups == []
    end

    test "preserves zeeky_boogie_doog admin override claim in identity" do
      identity =
        JwtAuthProvider.build_identity(%{
          "sub" => "admin-user",
          "zeeky_boogie_doog" => true
        })

      assert identity.id == "admin-user"
      assert identity.claims["zeeky_boogie_doog"] == true
    end

    test "verify_and_resolve preserves zeeky_boogie_doog through full JWT round-trip" do
      AuthHelper.with_auth_enabled(fn ->
        token =
          AuthHelper.sign_jwt(%{
            "sub" => "admin-user",
            "zeeky_boogie_doog" => true,
            "deploy_bpmn" => false
          })

        assert {:ok, identity} = JwtAuthProvider.verify_and_resolve(token)
        assert identity.claims["zeeky_boogie_doog"] == true
        assert identity.claims["deploy_bpmn"] == false
      end)
    end
  end
end
