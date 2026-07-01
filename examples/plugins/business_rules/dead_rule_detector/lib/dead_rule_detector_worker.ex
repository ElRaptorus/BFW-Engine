defmodule Examples.BusinessRules.DeadRuleDetector.DeadRuleDetectorWorker do
  @moduledoc """
  GenServer that deploys employee-benefits DMN and BPMN fixtures, runs the process
  with varied payloads, collects BRT execution traces, and logs a dead-rule report.
  """

  use GenServer

  require Logger

  alias EvilEngine.BPMN.Model.Definitions
  alias EvilEngine.EngineFacade
  alias Examples.BusinessRules.DeadRuleDetector.{
    RuleCoverageAnalyzer,
    TestPayloadGenerator
  }

  @decision_model_id "employee-benefits"
  @process_model_id "employee-benefits-process"
  @business_rule_task_flow_node_id "BRT_determine_benefits"
  @fni_poll_delay_ms 150

  @all_rule_ids [
    "rule_1",
    "rule_2",
    "rule_3",
    "rule_4",
    "rule_5",
    "rule_6",
    "rule_7",
    "rule_8",
    "rule_9",
    "rule_10",
    "rule_11",
    "rule_12"
  ]

  @doc "Starts the worker and schedules the bundled dead-rule detection demo."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) do
    GenServer.start_link(__MODULE__, options)
  end

  @doc "Returns the last dead-rule report produced by this worker, if any."
  @spec get_last_report(GenServer.server()) :: map() | nil
  def get_last_report(worker_pid) do
    GenServer.call(worker_pid, :get_last_report)
  end

  @impl true
  def init(options) do
    engine_facade = Keyword.fetch!(options, :facade)

    test_payloads =
      Keyword.get(options, :test_payloads, TestPayloadGenerator.generate_all())

    demo_identity =
      Keyword.get(
        options,
        :demo_identity,
        %EvilEngine.Types.Identity{
          id: "plugin:examples-dead-rule-detector",
          roles: ["plugin"],
          groups: []
        }
      )

    send(self(), {:run_dead_rule_detection, engine_facade, test_payloads, demo_identity})
    {:ok, %{last_report: nil}}
  end

  @impl true
  def handle_call(:get_last_report, _from, state) do
    {:reply, state.last_report, state}
  end

  @impl true
  def handle_info({:run_dead_rule_detection, engine_facade, test_payloads, demo_identity}, state) do
    last_report = run_dead_rule_detection_demo(engine_facade, test_payloads, demo_identity)
    {:noreply, %{state | last_report: last_report}}
  end

  def handle_info(_unknown_message, state), do: {:noreply, state}

  defp run_dead_rule_detection_demo(%EngineFacade{} = engine_facade, test_payloads, demo_identity) do
    Logger.info("dead_rule_detector: starting rule coverage analysis for #{@decision_model_id}")

    with :ok <- deploy_dmn_model(engine_facade),
         :ok <- deploy_bpmn_process(engine_facade),
         {:ok, process_version} <- fetch_latest_process_version(engine_facade),
         {:ok, started_runs} <- start_process_runs(engine_facade, process_version, test_payloads, demo_identity),
         traces <- collect_traces_after_delay(engine_facade, started_runs) do
      report =
        traces
        |> RuleCoverageAnalyzer.analyze(@all_rule_ids)
        |> Map.put(:process_model_id, @process_model_id)
        |> Map.put(:decision_model_id, @decision_model_id)

      log_report(report)
      report
    else
      {:error, reason} = error ->
        Logger.error("dead_rule_detector: analysis run failed: #{inspect(reason)}")
        error

      :deploy_aborted ->
        Logger.warning("dead_rule_detector: deploy aborted; skipping analysis")
        nil
    end
  end

  defp deploy_dmn_model(%EngineFacade{decisions: decisions}) do
    case decisions.deploy.([bundled_dmn_xml()]) do
      {:ok, _deploy_results} ->
        :ok

      {:error, :version_exists, _conflicts} ->
        Logger.info("dead_rule_detector: DMN version already deployed, continuing")
        :ok

      {:error, reason} ->
        Logger.error("dead_rule_detector: DMN deploy failed: #{inspect(reason)}")
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
            Logger.info("dead_rule_detector: BPMN version already deployed, continuing")
            :ok

          {:error, reason} ->
            Logger.error("dead_rule_detector: BPMN deploy failed: #{inspect(reason)}")
            :deploy_aborted
        end

      {:error, reason} ->
        Logger.error("dead_rule_detector: BPMN parse failed: #{inspect(reason)}")
        {:error, {:parse_failed, reason}}
    end
  end

  defp fetch_latest_process_version(%EngineFacade{processes: processes}) do
    case processes.get_latest_version.(@process_model_id) do
      {:ok, process_version} -> {:ok, process_version}
      {:error, reason} -> {:error, {:get_latest_version_failed, reason}}
    end
  end

  defp start_process_runs(_engine_facade, _process_version, [], _demo_identity) do
    {:ok, []}
  end

  defp start_process_runs(
         %EngineFacade{processes: processes},
         process_version,
         test_payloads,
         demo_identity
       ) do
    process_version_id = version_record_id(process_version)

    started_runs =
      Enum.map(test_payloads, fn payload ->
        process_instance_id = generate_process_instance_identifier()

        start_arguments = [
          process_instance_id: process_instance_id,
          process_version_id: process_version_id,
          payload: payload,
          identity: demo_identity
        ]

        case processes.start.(start_arguments) do
          {:ok, _process_instance_pid} ->
            {:ok, %{process_instance_id: process_instance_id, payload: payload}}

          {:error, reason} ->
            {:error, {:start_process_instance_failed, reason}}
        end
      end)

    case Enum.find(started_runs, &match?({:error, _}, &1)) do
      {:error, reason} -> {:error, reason}
      nil -> {:ok, Enum.map(started_runs, fn {:ok, run} -> run end)}
    end
  end

  defp collect_traces_after_delay(%EngineFacade{} = engine_facade, started_runs) do
    if started_runs == [] do
      []
    else
      Process.sleep(@fni_poll_delay_ms)
      collect_traces(engine_facade, started_runs)
    end
  end

  defp collect_traces(%EngineFacade{flow_node_instances: flow_node_instances}, started_runs) do
    Enum.flat_map(started_runs, fn %{process_instance_id: process_instance_id} ->
      case find_business_rule_fni(flow_node_instances, process_instance_id) do
        {:ok, flow_node_instance} ->
          case trace_from_flow_node_instance(flow_node_instance) do
            nil -> []
            trace -> [normalize_trace_for_analyzer(trace)]
          end

        {:error, _reason} ->
          []
      end
    end)
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

  defp trace_from_flow_node_instance(flow_node_instance) when is_map(flow_node_instance) do
    type_properties =
      Map.get(flow_node_instance, :type_properties) ||
        Map.get(flow_node_instance, "typeProperties", %{})

    Map.get(type_properties, :trace) || Map.get(type_properties, "trace")
  end

  defp trace_from_flow_node_instance(_invalid), do: nil

  defp normalize_trace_for_analyzer(trace) when is_map(trace) do
    decisions =
      trace
      |> map_value(:decisions, [])
      |> Enum.map(&normalize_decision_trace/1)

    %{"decisions" => decisions}
  end

  defp normalize_decision_trace(decision) when is_map(decision) do
    matched_rules =
      decision
      |> map_value(:matched_rules, [])
      |> Enum.map(fn rule ->
        %{"rule_id" => map_value(rule, :rule_id, nil)}
      end)

    %{"matched_rules" => matched_rules}
  end

  defp map_value(map, key, default) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key)) || default
  end

  defp pick_executable_process!(%Definitions{processes: processes}) do
    case Enum.find(processes, & &1.is_executable) do
      %EvilEngine.BPMN.Model.Process{} = process -> process
      nil -> raise ArgumentError, "dead_rule_detector example requires an executable process"
    end
  end

  defp version_record_id(process_version) when is_map(process_version) do
    Map.get(process_version, :id) || Map.get(process_version, "id")
  end

  defp generate_process_instance_identifier do
    random_bytes = :crypto.strong_rand_bytes(16)
    "pi-" <> Base.encode16(random_bytes, case: :lower)
  end

  defp log_report(report) when is_map(report) do
    Logger.info(
      "dead_rule_detector: report executions=#{report.execution_count} total_rules=#{report.total_rules} matched=#{report.matched_rules} dead=#{report.dead_rule_count} coverage=#{report.coverage_percent}%"
    )

    if report.dead_rule_count > 0 do
      Logger.warning(
        "dead_rule_detector: dead rules detected: #{inspect(report.dead_rules)}"
      )
    end
  end

  defp bundled_dmn_xml do
    [__DIR__, "..", "dmn", "employee_benefits.dmn"]
    |> Path.join()
    |> Path.expand()
    |> File.read!()
  end

  defp bundled_bpmn_xml do
    [__DIR__, "..", "bpmn", "employee_benefits_process.bpmn"]
    |> Path.join()
    |> Path.expand()
    |> File.read!()
  end
end
