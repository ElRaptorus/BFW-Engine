defmodule Examples.BusinessRules.DrdChainOrchestrator.DrdChainOrchestratorWorker do
  @moduledoc """
  GenServer that deploys the credit-underwriting DMN and BPMN fixtures, runs the
  process with sample applicant data, extracts the BRT trace, compares it with an
  ad-hoc evaluation trace, and logs the formatted DRD chain.
  """

  use GenServer

  require Logger

  alias EvilEngine.BPMN.Model.Definitions
  alias EvilEngine.DMN.EvaluationResult
  alias EvilEngine.DMN.EvaluationTrace
  alias EvilEngine.EngineFacade
  alias Examples.BusinessRules.DrdChainOrchestrator.TraceInspector

  @decision_model_id "credit-underwriting"
  @root_decision_element_id "Decision_underwriting_decision"
  @process_model_id "credit-underwriting-process"
  @business_rule_task_flow_node_id "BRT_underwrite_application"
  @fni_poll_delay_ms 150

  @doc "Starts the worker and schedules the bundled DRD chain demonstration."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) do
    GenServer.start_link(__MODULE__, options)
  end

  @doc "Returns the last orchestration report produced by this worker, if any."
  @spec get_last_report(GenServer.server()) :: map() | nil
  def get_last_report(worker_pid) do
    GenServer.call(worker_pid, :get_last_report)
  end

  @impl true
  def init(options) do
    engine_facade = Keyword.fetch!(options, :facade)

    sample_input =
      Keyword.get(options, :sample_input, default_sample_input())

    demo_identity =
      Keyword.get(
        options,
        :demo_identity,
        %EvilEngine.Types.Identity{
          id: "plugin:examples-drd-chain-orchestrator",
          roles: ["plugin"],
          groups: []
        }
      )

    send(self(), {:run_drd_chain_demo, engine_facade, sample_input, demo_identity})
    {:ok, %{last_report: nil}}
  end

  @impl true
  def handle_call(:get_last_report, _from, state) do
    {:reply, state.last_report, state}
  end

  @impl true
  def handle_info({:run_drd_chain_demo, engine_facade, sample_input, demo_identity}, state) do
    last_report = run_drd_chain_demo(engine_facade, sample_input, demo_identity)
    {:noreply, %{state | last_report: last_report}}
  end

  def handle_info(_unknown_message, state), do: {:noreply, state}

  defp run_drd_chain_demo(%EngineFacade{} = engine_facade, sample_input, demo_identity) do
    Logger.info("drd_chain_orchestrator: starting DRD chain demo for #{@decision_model_id}")

    with :ok <- deploy_dmn_model(engine_facade),
         :ok <- deploy_bpmn_process(engine_facade),
         {:ok, process_version} <- fetch_latest_process_version(engine_facade),
         {:ok, process_instance_id} <-
           start_process_instance(engine_facade, process_version, sample_input, demo_identity),
         {:ok, business_rule_trace} <-
           fetch_business_rule_trace_after_delay(engine_facade, process_instance_id),
         {:ok, ad_hoc_trace} <- evaluate_ad_hoc_trace(engine_facade, sample_input),
         business_rule_chain <- format_trace_chain(business_rule_trace),
         ad_hoc_chain <- format_trace_chain(ad_hoc_trace) do
      report = %{
        decision_model_id: @decision_model_id,
        root_decision_element_id: @root_decision_element_id,
        process_model_id: @process_model_id,
        process_instance_id: process_instance_id,
        decision_count: length(business_rule_chain),
        business_rule_chain: business_rule_chain,
        ad_hoc_chain: ad_hoc_chain,
        chains_match: business_rule_chain == ad_hoc_chain,
        business_rule_summary: TraceInspector.format_summary(business_rule_chain),
        ad_hoc_summary: TraceInspector.format_summary(ad_hoc_chain)
      }

      log_report(report)
      report
    else
      {:error, reason} = error ->
        Logger.error("drd_chain_orchestrator: demo run failed: #{inspect(reason)}")
        error

      :deploy_aborted ->
        Logger.warning("drd_chain_orchestrator: deploy aborted; skipping DRD chain demo")
        nil
    end
  end

  defp deploy_dmn_model(%EngineFacade{decisions: decisions}) do
    case decisions.deploy.([bundled_dmn_xml()]) do
      {:ok, _deploy_results} ->
        :ok

      {:error, :version_exists, _conflicts} ->
        Logger.info("drd_chain_orchestrator: DMN version already deployed, continuing")
        :ok

      {:error, reason} ->
        Logger.error("drd_chain_orchestrator: DMN deploy failed: #{inspect(reason)}")
        :deploy_aborted
    end
  end

  defp deploy_bpmn_process(%EngineFacade{processes: processes}) do
    xml = bundled_bpmn_xml()

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

        case processes.deploy.(deploy_batch) do
          {:ok, _deploy_results} ->
            :ok

          {:error, :version_exists, _conflicts} ->
            Logger.info("drd_chain_orchestrator: BPMN version already deployed, continuing")
            :ok

          {:error, reason} ->
            Logger.error("drd_chain_orchestrator: BPMN deploy failed: #{inspect(reason)}")
            :deploy_aborted
        end

      {:error, reason} ->
        Logger.error("drd_chain_orchestrator: BPMN parse failed: #{inspect(reason)}")
        {:error, {:parse_failed, reason}}
    end
  end

  defp fetch_latest_process_version(%EngineFacade{processes: processes}) do
    case processes.get_latest_version.(@process_model_id) do
      {:ok, process_version} -> {:ok, process_version}
      {:error, reason} -> {:error, {:get_latest_version_failed, reason}}
    end
  end

  defp start_process_instance(
         %EngineFacade{processes: processes},
         process_version,
         sample_input,
         demo_identity
       ) do
    process_instance_id = generate_process_instance_identifier()
    process_version_id = version_record_id(process_version)

    start_arguments = [
      process_instance_id: process_instance_id,
      process_version_id: process_version_id,
      payload: sample_input,
      identity: demo_identity
    ]

    case processes.start.(start_arguments) do
      {:ok, _process_instance_pid} ->
        {:ok, process_instance_id}

      {:error, reason} ->
        {:error, {:start_process_instance_failed, reason}}
    end
  end

  defp fetch_business_rule_trace_after_delay(%EngineFacade{} = engine_facade, process_instance_id) do
    Process.sleep(@fni_poll_delay_ms)

    case find_business_rule_fni(engine_facade.flow_node_instances, process_instance_id) do
      {:ok, flow_node_instance} ->
        case trace_from_flow_node_instance(flow_node_instance) do
          nil -> {:error, {:trace_missing, process_instance_id}}
          trace -> {:ok, trace}
        end

      {:error, reason} ->
        {:error, {:get_flow_node_instance_failed, reason}}
    end
  end

  defp find_business_rule_fni(flow_node_instances, process_instance_id) do
    case flow_node_instances.list_for_process_instance.(process_instance_id) do
      {:ok, all_flow_node_instances} ->
        case Enum.find(all_flow_node_instances, &brt_flow_node_match?/1) do
          nil -> {:error, :brt_fni_not_found}
          flow_node_instance -> {:ok, flow_node_instance}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp brt_flow_node_match?(flow_node_instance) when is_map(flow_node_instance) do
    flow_node_id =
      Map.get(flow_node_instance, :flow_node_id) ||
        Map.get(flow_node_instance, "flow_node_id")

    flow_node_id == @business_rule_task_flow_node_id
  end

  defp evaluate_ad_hoc_trace(%EngineFacade{decisions: decisions}, sample_input) do
    evaluate_options = [decision_model_id: @root_decision_element_id]

    case decisions.evaluate.(@decision_model_id, sample_input, evaluate_options) do
      {:ok, %EvaluationResult{trace: %EvaluationTrace{} = trace}} ->
        {:ok, EvaluationTrace.to_json_map(trace)}

      {:ok, evaluation_result} when is_map(evaluation_result) ->
        trace =
          Map.get(evaluation_result, :trace) ||
            Map.get(evaluation_result, "trace") ||
            %{}

        {:ok, normalize_trace_map(trace)}

      {:error, reason} ->
        {:error, {:ad_hoc_evaluate_failed, reason}}
    end
  end

  defp trace_from_flow_node_instance(flow_node_instance) when is_map(flow_node_instance) do
    type_properties =
      Map.get(flow_node_instance, :type_properties) ||
        Map.get(flow_node_instance, "typeProperties", %{})

    Map.get(type_properties, :trace) || Map.get(type_properties, "trace")
  end

  defp trace_from_flow_node_instance(_invalid), do: nil

  defp normalize_trace_map(%EvaluationTrace{} = trace), do: EvaluationTrace.to_json_map(trace)
  defp normalize_trace_map(trace) when is_map(trace), do: trace
  defp normalize_trace_map(_invalid), do: %{}

  defp format_trace_chain(trace) do
    trace
    |> normalize_trace_map()
    |> TraceInspector.format_chain()
  end

  defp pick_executable_process!(%Definitions{processes: processes}) do
    case Enum.find(processes, & &1.is_executable) do
      %EvilEngine.BPMN.Model.Process{} = process ->
        process

      nil ->
        raise ArgumentError, "drd_chain_orchestrator example requires an executable process"
    end
  end

  defp version_record_id(process_version) when is_map(process_version) do
    Map.get(process_version, :id) || Map.get(process_version, "id")
  end

  defp generate_process_instance_identifier do
    random_bytes = :crypto.strong_rand_bytes(16)
    "pi-" <> Base.encode16(random_bytes, case: :lower)
  end

  defp default_sample_input do
    %{
      "applicantAge" => 42,
      "annualIncome" => 75_000,
      "creditHistory" => "good",
      "existingDebt" => 15_000,
      "requestedAmount" => 200_000,
      "employmentStatus" => "employed"
    }
  end

  defp log_report(report) when is_map(report) do
    Logger.info(
      "drd_chain_orchestrator: report decisions=#{report.decision_count} chains_match=#{report.chains_match}"
    )

    Logger.info("drd_chain_orchestrator: BRT trace\n#{report.business_rule_summary}")
    Logger.info("drd_chain_orchestrator: ad-hoc trace\n#{report.ad_hoc_summary}")
  end

  defp bundled_dmn_xml do
    [__DIR__, "..", "dmn", "credit_underwriting.dmn"]
    |> Path.join()
    |> Path.expand()
    |> File.read!()
  end

  defp bundled_bpmn_xml do
    [__DIR__, "..", "bpmn", "credit_underwriting_process.bpmn"]
    |> Path.join()
    |> Path.expand()
    |> File.read!()
  end
end
