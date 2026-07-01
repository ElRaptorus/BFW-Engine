defmodule Examples.Plugins.GithubBpmnDeployer.GithubBpmnDeployerPlugin do
  @moduledoc """
  In-BEAM plugin that fetches BPMN files from a GitHub repository and
  deploys them to the engine exactly once at startup.

  ## Environment variables

  | Variable | Required | Default | Description |
  |----------|----------|---------|-------------|
  | `GITHUB_BPMN_REPO_OWNER` | yes | — | Repository owner or organisation |
  | `GITHUB_BPMN_REPO_NAME` | yes | — | Repository name |
  | `GITHUB_ACCESS_TOKEN` | yes | — | Personal access token (needs `repo` scope for private repos, `public_repo` for public) |
  | `GITHUB_BPMN_BRANCH` | no | `main` | Branch to read from |
  | `GITHUB_BPMN_PATH` | no | *(root)* | Directory inside the repo that contains `.bpmn` files |
  | `GITHUB_API_BASE_URL` | no | `https://api.github.com` | API base URL (set for GitHub Enterprise) |

  ## Lifecycle

  `on_load/1` validates that the three required env vars are present and stashes
  the facade.  `on_ready/1` starts the worker GenServer which performs the
  fetch → parse → deploy pipeline once, then stops.
  """

  @behaviour EvilEngine.Plugin

  require Logger

  alias Examples.Plugins.GithubBpmnDeployer.FacadeStore
  alias Examples.Plugins.GithubBpmnDeployer.GithubBpmnDeployerWorker

  @required_env_vars ~w(GITHUB_BPMN_REPO_OWNER GITHUB_BPMN_REPO_NAME GITHUB_ACCESS_TOKEN)

  @impl true
  def on_load(engine_facade) do
    case validate_environment() do
      :ok ->
        :ok = FacadeStore.put(engine_facade)
        Logger.info("github_bpmn_deployer: configuration validated, facade stored")
        :ok

      {:error, missing_variables} ->
        reason = "missing required env vars: #{Enum.join(missing_variables, ", ")}"
        Logger.error("github_bpmn_deployer: #{reason}")
        {:error, {:missing_configuration, missing_variables}}
    end
  end

  @impl true
  def on_ready(_engine_facade) do
    case FacadeStore.get() do
      nil ->
        {:error, :facade_missing_from_store}

      stored_facade ->
        case GithubBpmnDeployerWorker.start_link(facade: stored_facade) do
          {:ok, _pid} -> :ok
          {:error, reason} -> {:error, {:worker_start_failed, reason}}
        end
    end
  end

  defp validate_environment do
    missing =
      Enum.filter(@required_env_vars, fn variable_name ->
        is_nil(System.get_env(variable_name)) or System.get_env(variable_name) == ""
      end)

    if missing == [], do: :ok, else: {:error, missing}
  end
end
