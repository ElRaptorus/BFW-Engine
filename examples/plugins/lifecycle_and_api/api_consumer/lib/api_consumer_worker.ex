defmodule Examples.Plugins.ApiConsumer.Worker do
  @moduledoc """
  Illustrates a plugin-initiated orchestration flow that fans out across the
  `EvilEngine.EngineFacade` namespaces. All network effects happen through the
  closures installed during engine boot — there is no direct `Ash` access here.

  Copy into an OTP application that already depends on `core_bpmn` (for
  `EvilEngine.BPMN.parse_and_validate/1`) and `core_types` (for
  `EvilEngine.Types.Identity`).
  """

  use GenServer

  require Logger

  alias EvilEngine.BPMN.Model.Definitions

  @doc "Schedules the bundled orchestration demo using options such as the facade and demo identity."
  @impl true
  def init(options) do
    engine_facade = Keyword.fetch!(options, :facade)

    user_task_flow_node_instance_id =
      Keyword.get(
        options,
        :demo_user_task_flow_node_instance_id,
        System.get_env("API_CONSUMER_DEMO_USER_TASK_FNI_ID", "")
      )

    identity =
      Keyword.get(
        options,
        :demo_identity,
        %EvilEngine.Types.Identity{
          id: "plugin:examples-api-consumer",
          roles: ["plugin"],
          groups: ["reviewers"]
        }
      )

    send(self(), {:run_demo, engine_facade, user_task_flow_node_instance_id, identity})
    {:ok, %{}}
  end

  @doc "Runs the demo once on {:run_demo, ...} or ignores unrelated messages without crashing."
  @impl true
  def handle_info({:run_demo, engine_facade, user_task_flow_node_instance_id, identity}, state) do
    _result = run_orchestration_demo(engine_facade, user_task_flow_node_instance_id, identity)
    {:noreply, state}
  end

  def handle_info(_unknown_message, state), do: {:noreply, state}

  @doc "Starts the worker with keyword options passed through to init."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) do
    GenServer.start_link(__MODULE__, options)
  end

  defp run_orchestration_demo(engine_facade, user_task_flow_node_instance_id, identity) do
    xml = bundled_bpmn_xml()

    Logger.info("api_consumer step_1_parse_and_validate")

    case EvilEngine.BPMN.parse_and_validate(xml) do
      {:ok, %Definitions{} = definitions} ->
        executable_process = pick_executable_process!(definitions)

        deploy_batch = [
          %{
            process_model_id: executable_process.id,
            version: executable_process.version,
            xml: xml,
            definitions: definitions
          }
        ]

        Logger.info("api_consumer step_1_processes_deploy_batch")

        case engine_facade.processes.deploy.(deploy_batch) do
          {:ok, deploy_results} ->
            deployed_descriptor = List.first(deploy_results)

            Logger.info(
              "api_consumer step_2_processes_get_latest_version model=#{deployed_descriptor.process_model_id}"
            )

            case engine_facade.processes.get_latest_version.(deployed_descriptor.process_model_id) do
              {:ok, process_version} ->
                process_instance_id = generate_process_instance_identifier()

                start_arguments = [
                  process_instance_id: process_instance_id,
                  process_version_id: process_version.id,
                  payload: %{"note" => "api_consumer_example"},
                  identity: identity
                ]

                Logger.info("api_consumer step_3_processes_start")

                case engine_facade.processes.start.(start_arguments) do
                  {:ok, _process_instance_pid} ->
                    Logger.info("api_consumer step_4_process_instances_get snapshot")

                    case engine_facade.process_instances.get.(process_instance_id) do
                      {:ok, first_snapshot} ->
                        Logger.info(
                          "api_consumer step_4_process_instance_state=#{inspect(Map.get(first_snapshot, :state))}"
                        )

                        finish_user_task_if_configured(
                          engine_facade,
                          process_instance_id,
                          user_task_flow_node_instance_id,
                          identity
                        )

                        Logger.info("api_consumer step_5_process_instances_get final snapshot")

                        case engine_facade.process_instances.get.(process_instance_id) do
                          {:ok, final_snapshot} ->
                            Logger.info(
                              "api_consumer step_5_process_instance_state=#{inspect(Map.get(final_snapshot, :state))}"
                            )

                          unexpected_outcome ->
                            Logger.warning(
                              "api_consumer step_5_process_instances_get unexpected=#{inspect(unexpected_outcome)}"
                            )
                        end

                        :ok

                      {:error, reason} ->
                        Logger.error("api_consumer step_4_process_instances_get failed: #{inspect(reason)}")
                        {:error, {:get_process_instance_failed, reason}}
                    end

                  {:error, reason} ->
                    Logger.error("api_consumer step_3_processes_start failed: #{inspect(reason)}")
                    {:error, {:start_process_instance_failed, reason}}
                end

              {:error, reason} ->
                Logger.error("api_consumer step_2_processes_get_latest_version failed: #{inspect(reason)}")
                {:error, {:get_latest_version_failed, reason}}
            end

          {:error, reason} ->
            Logger.error("api_consumer step_1_processes_deploy failed: #{inspect(reason)}")
            {:error, {:deploy_failed, reason}}
        end

      {:error, reason} ->
        Logger.error("api_consumer step_1_parse_and_validate failed: #{inspect(reason)}")
        {:error, {:parse_failed, reason}}
    end
  end

  defp finish_user_task_if_configured(
         engine_facade,
         process_instance_id,
         user_task_flow_node_instance_id,
         identity
       ) do
    trimmed_flow_node_instance_id = String.trim(user_task_flow_node_instance_id)

    if trimmed_flow_node_instance_id == "" do
      Logger.info(
        "api_consumer step_4_user_tasks_finish skipped (export API_CONSUMER_DEMO_USER_TASK_FNI_ID to exercise finish/3)"
      )
    else
      Logger.info("api_consumer step_4_user_tasks_finish")

      case engine_facade.user_tasks.finish.(
             trimmed_flow_node_instance_id,
             %{"approved" => true},
             identity
           ) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.error("api_consumer step_4_user_tasks_finish failed: #{inspect(reason)}")
      end
    end
  end

  defp pick_executable_process!(%Definitions{processes: processes}) do
    case Enum.find(processes, & &1.is_executable) do
      %EvilEngine.BPMN.Model.Process{} = process -> process
      nil -> raise ArgumentError, "api_consumer example requires an executable process in bundled BPMN"
    end
  end

  defp bundled_bpmn_xml do
    path =
      [__DIR__, "..", "bpmn", "api_demo_process.bpmn"]
      |> Path.join()
      |> Path.expand()

    File.read!(path)
  end

  defp generate_process_instance_identifier do
    random_bytes = :crypto.strong_rand_bytes(16)
    "pi-" <> Base.encode16(random_bytes, case: :lower)
  end
end
