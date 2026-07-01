defmodule EvilEngine.Integration.ExampleAuthProvidersTest do
  @moduledoc """
  Verifies that the example auth provider plugins under
  `examples/plugins/auth_providers/` are compilable, implement
  the `AuthProvider` behaviour correctly, and produce valid
  `%Identity{}` structs.
  """
  use EvilEngine.IntegrationCase, async: false

  @compile {:no_warn_undefined,
            [
              MyCompany.LdapAuthProvider,
              MyCompany.LdapPlugin,
              MyCompany.CompanyGraphAuthProvider,
              MyCompany.CompanyGraphPlugin
            ]}

  alias EvilEngine.Auth.ProviderRegistry
  alias EvilEngine.Types.Identity

  @examples_root Path.expand("../../../examples/plugins/auth_providers", __DIR__)

  setup_all do
    Code.require_file(Path.join(@examples_root, "ldap/lib/ldap_auth_provider.ex"))
    Code.require_file(Path.join(@examples_root, "ldap/lib/ldap_plugin.ex"))
    Code.require_file(Path.join(@examples_root, "companygraph/lib/companygraph_auth_provider.ex"))
    Code.require_file(Path.join(@examples_root, "companygraph/lib/companygraph_plugin.ex"))
    :ok
  end

  setup do
    ProviderRegistry.reset_to_default()
    on_exit(fn -> ProviderRegistry.reset_to_default() end)
    :ok
  end

  # -----------------------------------------------------------------------
  # LDAP example
  # -----------------------------------------------------------------------

  describe "LDAP example provider" do
    test "implements AuthProvider behaviour" do
      behaviours =
        MyCompany.LdapAuthProvider.__info__(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert EvilEngine.Plugin.AuthProvider in behaviours
    end

    test "verify_and_resolve/1 accepts valid LDAP token" do
      assert {:ok, %Identity{} = identity} =
               MyCompany.LdapAuthProvider.verify_and_resolve("valid-ldap-jdoe")

      assert identity.id == "jdoe"
      assert identity.roles == ["engineering", "deploy"]
      assert identity.groups == ["engineering", "deploy"]
      assert identity.claims["sub"] == "jdoe"
      assert identity.claims["name"] == "LDAP User jdoe"
      assert identity.claims["ldap_attrs"] == %{"department" => "Engineering"}
    end

    test "verify_and_resolve/1 rejects invalid token" do
      assert {:error, :invalid_token} =
               MyCompany.LdapAuthProvider.verify_and_resolve("garbage-token")
    end

    test "verify_and_resolve/1 rejects empty token" do
      assert {:error, :invalid_token} =
               MyCompany.LdapAuthProvider.verify_and_resolve("")
    end

    test "works end-to-end when registered as active provider" do
      with_config(:api_auth, :auth_disabled, false, fn ->
        ProviderRegistry.register_provider(MyCompany.LdapAuthProvider)

        conn =
          conn(:get, "/stats")
          |> put_req_header("authorization", "Bearer valid-ldap-e42")
          |> route()

        assert conn.status == 200
      end)
    end

    test "rejects invalid token end-to-end when registered" do
      with_config(:api_auth, :auth_disabled, false, fn ->
        ProviderRegistry.register_provider(MyCompany.LdapAuthProvider)

        conn =
          conn(:get, "/stats")
          |> put_req_header("authorization", "Bearer some-random-jwt")
          |> route()

        assert conn.status == 401
      end)
    end
  end

  describe "LDAP example plugin module" do
    test "implements Plugin behaviour" do
      behaviours =
        MyCompany.LdapPlugin.__info__(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert EvilEngine.Plugin in behaviours
    end

    test "on_load registers the LDAP auth provider" do
      facade = EvilEngine.Plugins.Loader.facade_for_plugin("test-ldap-plugin")
      assert :ok = MyCompany.LdapPlugin.on_load(facade)

      assert ProviderRegistry.active_provider() == MyCompany.LdapAuthProvider
    end

    test "on_ready returns :ok" do
      facade = EvilEngine.Plugins.Loader.facade_for_plugin("test-ldap-plugin")
      assert :ok = MyCompany.LdapPlugin.on_ready(facade)
    end
  end

  # -----------------------------------------------------------------------
  # CompanyGraph example — auth provider
  # -----------------------------------------------------------------------

  describe "CompanyGraph example provider" do
    test "implements AuthProvider behaviour" do
      behaviours =
        MyCompany.CompanyGraphAuthProvider.__info__(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert EvilEngine.Plugin.AuthProvider in behaviours
    end

    test "admin token produces full engine claims" do
      assert {:ok, %Identity{} = identity} =
               MyCompany.CompanyGraphAuthProvider.verify_and_resolve("cg-admin-boss-1")

      assert identity.id == "boss-1"
      assert identity.roles == ["admin"]
      assert identity.groups == ["platform-engineering"]

      assert identity.claims["sub"] == "boss-1"
      assert identity.claims["email"] == "boss-1@corp.example.com"
      assert identity.claims["name"] == "Employee boss-1"
      assert identity.claims["org_unit"] == "Engineering / Platform"
      assert identity.claims["companygraph"] == %{"cost_center" => "CC-4200", "location" => "Berlin"}

      assert identity.claims["deploy_bpmn"] == true
      assert identity.claims["deploy_dmn"] == true
      assert identity.claims["delete_dmn"] == true
      assert identity.claims["abort_process_instance"] == "all"
      assert identity.claims["retry_process_instance"] == "all"
      assert identity.claims["zeeky_boogie_doog"] == true
      assert identity.claims["lane:Engineering"] == true
      assert identity.claims["lane:Operations"] == true
      assert identity.claims["lane:Management"] == true
    end

    test "deployer token produces deploy + limited lane claims" do
      assert {:ok, %Identity{} = identity} =
               MyCompany.CompanyGraphAuthProvider.verify_and_resolve("cg-deployer-dev-42")

      assert identity.id == "dev-42"
      assert identity.roles == ["deployer"]
      assert identity.groups == ["platform-engineering", "bpmn-squad"]

      assert identity.claims["deploy_bpmn"] == true
      assert identity.claims["deploy_dmn"] == true
      assert identity.claims["abort_process_instance"] == "own"
      assert identity.claims["retry_process_instance"] == "none"
      assert identity.claims["lane:Engineering"] == true

      refute Map.has_key?(identity.claims, "delete_dmn")
      refute Map.has_key?(identity.claims, "zeeky_boogie_doog")
      refute Map.has_key?(identity.claims, "lane:Operations")
      refute Map.has_key?(identity.claims, "lane:Management")
    end

    test "viewer token produces read-only lane claims" do
      assert {:ok, %Identity{} = identity} =
               MyCompany.CompanyGraphAuthProvider.verify_and_resolve("cg-viewer-readonly-7")

      assert identity.id == "readonly-7"
      assert identity.roles == ["viewer"]
      assert identity.groups == ["operations"]

      assert identity.claims["lane:Operations"] == true
      assert identity.claims["abort_process_instance"] == "none"
      assert identity.claims["retry_process_instance"] == "none"

      refute Map.has_key?(identity.claims, "deploy_bpmn")
      refute Map.has_key?(identity.claims, "deploy_dmn")
      refute Map.has_key?(identity.claims, "zeeky_boogie_doog")
      refute Map.has_key?(identity.claims, "lane:Engineering")
    end

    test "verify_and_resolve/1 rejects invalid token" do
      assert {:error, :invalid_token} =
               MyCompany.CompanyGraphAuthProvider.verify_and_resolve("invalid-token")
    end

    test "verify_and_resolve/1 rejects empty token" do
      assert {:error, :invalid_token} =
               MyCompany.CompanyGraphAuthProvider.verify_and_resolve("")
    end

    test "admin works end-to-end when registered as active provider" do
      with_config(:api_auth, :auth_disabled, false, fn ->
        ProviderRegistry.register_provider(MyCompany.CompanyGraphAuthProvider)

        conn =
          conn(:get, "/stats")
          |> put_req_header("authorization", "Bearer cg-admin-emp-1")
          |> route()

        assert conn.status == 200
      end)
    end

    test "deployer works end-to-end when registered" do
      with_config(:api_auth, :auth_disabled, false, fn ->
        ProviderRegistry.register_provider(MyCompany.CompanyGraphAuthProvider)

        conn =
          conn(:get, "/stats")
          |> put_req_header("authorization", "Bearer cg-deployer-emp-2")
          |> route()

        assert conn.status == 200
      end)
    end

    test "viewer works end-to-end when registered" do
      with_config(:api_auth, :auth_disabled, false, fn ->
        ProviderRegistry.register_provider(MyCompany.CompanyGraphAuthProvider)

        conn =
          conn(:get, "/stats")
          |> put_req_header("authorization", "Bearer cg-viewer-emp-3")
          |> route()

        assert conn.status == 200
      end)
    end

    test "rejects invalid token end-to-end when registered" do
      with_config(:api_auth, :auth_disabled, false, fn ->
        ProviderRegistry.register_provider(MyCompany.CompanyGraphAuthProvider)

        conn =
          conn(:get, "/stats")
          |> put_req_header("authorization", "Bearer not-a-cg-token")
          |> route()

        assert conn.status == 401
      end)
    end
  end

  # -----------------------------------------------------------------------
  # CompanyGraph example — plugin module
  # -----------------------------------------------------------------------

  describe "CompanyGraph example plugin module" do
    test "implements Plugin behaviour" do
      behaviours =
        MyCompany.CompanyGraphPlugin.__info__(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert EvilEngine.Plugin in behaviours
    end

    test "on_load registers the CompanyGraph auth provider" do
      facade = EvilEngine.Plugins.Loader.facade_for_plugin("test-cg-plugin")
      assert :ok = MyCompany.CompanyGraphPlugin.on_load(facade)

      assert ProviderRegistry.active_provider() == MyCompany.CompanyGraphAuthProvider
    end

    test "on_ready returns :ok (permission seeding is stubbed)" do
      facade = EvilEngine.Plugins.Loader.facade_for_plugin("test-cg-plugin")
      assert :ok = MyCompany.CompanyGraphPlugin.on_ready(facade)
    end

    test "exposes tool name and permission catalog" do
      assert MyCompany.CompanyGraphPlugin.tool_name() == "my-workflow-app"
      assert MyCompany.CompanyGraphPlugin.permissions() == ["can_deploy_processes", "can_view_instances"]
    end
  end
end
