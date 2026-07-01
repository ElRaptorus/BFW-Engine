defmodule Examples.Plugins.GithubBpmnDeployer.GithubBpmnDeployerWorker do
  @moduledoc """
  GenServer that runs the GitHub → Engine deploy pipeline exactly once.

  1. Read the GitHub repository configuration from environment variables
  2. List all `.bpmn` files in the configured directory
  3. Download each file's raw content
  4. Parse and validate via `EvilEngine.BPMN.parse_and_validate/1`
  5. Deploy the valid definitions as a single batch via `facade.processes.deploy`
  6. Log a summary (deployed / skipped / failed) and stop

  The worker is started by `GithubBpmnDeployerPlugin.on_ready/1` and
  self-terminates after the pipeline completes.  It does not supervise
  itself — a failed deploy logs errors but does not crash the engine.
  """

  use GenServer

  require Logger

  alias EvilEngine.BPMN.Model.Definitions
  alias Examples.Plugins.GithubBpmnDeployer.GithubClient

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) do
    GenServer.start_link(__MODULE__, options)
  end

  @impl true
  def init(options) do
    engine_facade = Keyword.fetch!(options, :facade)
    github_client = Keyword.get(options, :github_client, GithubClient)
    send(self(), {:run_deploy, engine_facade, github_client})
    {:ok, %{}}
  end

  @impl true
  def handle_info({:run_deploy, engine_facade, github_client}, state) do
    try do
      run_deploy_pipeline(engine_facade, github_client)
    rescue
      exception ->
        Logger.error(
          "github_bpmn_deployer: unexpected error during deploy pipeline: " <>
            Exception.format(:error, exception, __STACKTRACE__)
        )
    end

    {:stop, :normal, state}
  end

  def handle_info(_unknown_message, state), do: {:noreply, state}

  defp run_deploy_pipeline(engine_facade, github_client) do
    config = github_client.build_config()

    Logger.info(
      "github_bpmn_deployer: fetching BPMN files from #{config.owner}/#{config.repo}" <>
        " (branch=#{config.branch}, path=#{inspect(config.path)})"
    )

    case github_client.list_bpmn_files(config) do
      {:ok, []} ->
        Logger.info("github_bpmn_deployer: no .bpmn files found — nothing to deploy")

      {:ok, file_entries} ->
        Logger.info("github_bpmn_deployer: found #{length(file_entries)} .bpmn file(s), downloading…")
        deploy_files(engine_facade, github_client, config, file_entries)

      {:error, reason} ->
        Logger.error("github_bpmn_deployer: failed to list repository contents: #{inspect(reason)}")
    end
  end

  defp deploy_files(engine_facade, github_client, config, file_entries) do
    download_results =
      Enum.map(file_entries, fn entry ->
        Logger.info("github_bpmn_deployer: downloading #{entry.name}")

        case github_client.download_raw(entry.download_url, config.token) do
          {:ok, xml} -> {:ok, entry.name, xml}
          {:error, reason} -> {:error, entry.name, reason}
        end
      end)

    {downloaded, download_failures} =
      Enum.split_with(download_results, &match?({:ok, _, _}, &1))

    Enum.each(download_failures, fn {:error, filename, reason} ->
      Logger.warning("github_bpmn_deployer: failed to download #{filename}: #{inspect(reason)}")
    end)

    parse_results =
      Enum.map(downloaded, fn {:ok, filename, xml} ->
        case EvilEngine.BPMN.parse_and_validate(xml) do
          {:ok, %Definitions{} = definitions} ->
            {:ok, filename, xml, definitions}

          {:error, reason} ->
            {:error, filename, reason}
        end
      end)

    {parsed, parse_failures} =
      Enum.split_with(parse_results, &match?({:ok, _, _, _}, &1))

    Enum.each(parse_failures, fn {:error, filename, reason} ->
      Logger.warning("github_bpmn_deployer: #{filename} failed validation: #{inspect(reason)}")
    end)

    if parsed == [] do
      Logger.warning("github_bpmn_deployer: no valid BPMN files to deploy")
    else
      deploy_batch =
        parsed
        |> Enum.map(fn {:ok, filename, xml, definitions} ->
          case pick_executable_process(definitions, filename) do
            nil ->
              nil

            executable_process ->
              %{
                process_model_id: executable_process.id,
                version: executable_process.version,
                xml: xml,
                definitions: definitions
              }
          end
        end)
        |> Enum.reject(&is_nil/1)

      if deploy_batch == [] do
        Logger.warning("github_bpmn_deployer: none of the BPMN files contain an executable process")
      else
        Logger.info("github_bpmn_deployer: deploying #{length(deploy_batch)} process definition(s)…")

        case engine_facade.processes.deploy.(deploy_batch) do
          {:ok, deploy_results} ->
            Enum.each(deploy_results, fn result ->
              Logger.info(
                "github_bpmn_deployer: deployed #{result.process_model_id} v#{result.version}"
              )
            end)

            Logger.info(
              "github_bpmn_deployer: done — " <>
                "#{length(deploy_results)} deployed, " <>
                "#{length(download_failures)} download failures, " <>
                "#{length(parse_failures)} parse failures"
            )

          {:error, :version_exists, conflicts} ->
            Logger.info(
              "github_bpmn_deployer: some versions already deployed (idempotent): #{inspect(conflicts)}"
            )

          {:error, reason} ->
            Logger.error("github_bpmn_deployer: batch deploy failed: #{inspect(reason)}")
        end
      end
    end
  end

  defp pick_executable_process(%Definitions{processes: processes}, filename) do
    case Enum.find(processes, & &1.is_executable) do
      nil ->
        Logger.warning("github_bpmn_deployer: #{filename} has no executable process — skipping")
        nil

      process ->
        process
    end
  end
end
