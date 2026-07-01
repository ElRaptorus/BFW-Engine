defmodule Examples.Plugins.GithubBpmnDeployer.GithubBpmnDeployerPluginTest do
  use ExUnit.Case

  alias EvilEngine.EngineFacade
  alias Examples.Plugins.GithubBpmnDeployer.GithubBpmnDeployerPlugin

  describe "on_load/1" do
    test "returns :ok when all required env vars are set" do
      set_required_env_vars()

      facade = build_test_facade()
      assert :ok = GithubBpmnDeployerPlugin.on_load(facade)
    after
      clear_env_vars()
    end

    test "returns error when GITHUB_BPMN_REPO_OWNER is missing" do
      System.put_env("GITHUB_BPMN_REPO_NAME", "my-repo")
      System.put_env("GITHUB_ACCESS_TOKEN", "ghp_test_token")

      facade = build_test_facade()
      assert {:error, {:missing_configuration, missing}} = GithubBpmnDeployerPlugin.on_load(facade)
      assert "GITHUB_BPMN_REPO_OWNER" in missing
    after
      clear_env_vars()
    end

    test "returns error when GITHUB_BPMN_REPO_NAME is missing" do
      System.put_env("GITHUB_BPMN_REPO_OWNER", "acme-corp")
      System.put_env("GITHUB_ACCESS_TOKEN", "ghp_test_token")

      facade = build_test_facade()
      assert {:error, {:missing_configuration, missing}} = GithubBpmnDeployerPlugin.on_load(facade)
      assert "GITHUB_BPMN_REPO_NAME" in missing
    after
      clear_env_vars()
    end

    test "returns error when GITHUB_ACCESS_TOKEN is missing" do
      System.put_env("GITHUB_BPMN_REPO_OWNER", "acme-corp")
      System.put_env("GITHUB_BPMN_REPO_NAME", "my-repo")

      facade = build_test_facade()
      assert {:error, {:missing_configuration, missing}} = GithubBpmnDeployerPlugin.on_load(facade)
      assert "GITHUB_ACCESS_TOKEN" in missing
    after
      clear_env_vars()
    end

    test "returns error when all required env vars are missing" do
      facade = build_test_facade()
      assert {:error, {:missing_configuration, missing}} = GithubBpmnDeployerPlugin.on_load(facade)
      assert length(missing) == 3
    after
      clear_env_vars()
    end

    test "treats empty string as missing" do
      System.put_env("GITHUB_BPMN_REPO_OWNER", "")
      System.put_env("GITHUB_BPMN_REPO_NAME", "my-repo")
      System.put_env("GITHUB_ACCESS_TOKEN", "ghp_test_token")

      facade = build_test_facade()
      assert {:error, {:missing_configuration, missing}} = GithubBpmnDeployerPlugin.on_load(facade)
      assert "GITHUB_BPMN_REPO_OWNER" in missing
    after
      clear_env_vars()
    end
  end

  describe "on_ready/1" do
    test "returns error when facade was never stored (on_load failed)" do
      kill_facade_store_if_running()

      facade = build_test_facade()
      assert {:error, :facade_missing_from_store} = GithubBpmnDeployerPlugin.on_ready(facade)
    end
  end

  defp build_test_facade do
    %EngineFacade{
      engine_id: "test-engine",
      engine_name: "test-engine",
      version: "0.0.0-test"
    }
  end

  defp set_required_env_vars do
    System.put_env("GITHUB_BPMN_REPO_OWNER", "acme-corp")
    System.put_env("GITHUB_BPMN_REPO_NAME", "bpmn-definitions")
    System.put_env("GITHUB_ACCESS_TOKEN", "ghp_test_token_12345")
  end

  defp clear_env_vars do
    Enum.each(
      ~w(GITHUB_BPMN_REPO_OWNER GITHUB_BPMN_REPO_NAME GITHUB_ACCESS_TOKEN GITHUB_BPMN_BRANCH GITHUB_BPMN_PATH GITHUB_API_BASE_URL),
      &System.delete_env/1
    )

    kill_facade_store_if_running()
  end

  defp kill_facade_store_if_running do
    case Process.whereis(Examples.Plugins.GithubBpmnDeployer.FacadeStore) do
      nil -> :ok
      pid -> Agent.stop(pid)
    end
  end
end
