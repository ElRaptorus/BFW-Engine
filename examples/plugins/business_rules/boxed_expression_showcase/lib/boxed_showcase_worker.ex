defmodule Examples.BusinessRules.BoxedExpressionShowcase.BoxedShowcaseWorker do
  @moduledoc """
  GenServer that deploys the expression-showcase DMN and BPMN fixtures, runs a
  Business Rule Task process, collects the execution trace, evaluates the root
  decision ad-hoc, and logs an expression-type report.
  """

  use GenServer

  require Logger

  alias EvilEngine.BPMN.Model.Definitions
  alias EvilEngine.DMN.EvaluationResult
  alias EvilEngine.EngineFacade
  alias Examples.BusinessRules.BoxedExpressionShowcase.ExpressionTypeReporter

  @decision_model_id "expression-showcase"
  @root_decision_element_id "Decision_total_compensation"
  @process_model_id "showcase-runner-process"
  @business_rule_task_flow_node_id "BRT_calculate_compensation"
  @fni_poll_delay_ms 150

  @default_sample_input %{
    "baseSalary" => 75_000,
    "department" => "engineering",
    "performanceRating" => 4,
    "yearsOfService" => 8,
    "certifications" => ["AWS", "PMP"]
  }

  @doc "Starts the worker and schedules the bundled boxed-expression showcase demo."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) do
    GenServer.start_link(__MODULE__, options)
  end

  @doc "Returns the last expression-type report produced by this worker, if any."
  @spec get_last_report(GenServer.server()) :: [map()] | nil
  def get_last_report(worker_pid) do
    GenServer.call(worker_pid, :get_last_report)
  end

  @impl true
  def init(options) do
    engine_facade = Keyword.fetch!(options, :facade)

    sample_input = Keyword.get(options, :sample_input, @default_sample_input)

    demo_identity =
      Keyword.get(
        options,
        :demo_identity,
        %EvilEngine.Types.Identity{
          id: "plugin:examples-boxed-expression-showcase",
          roles: ["plugin"],
          groups: []
        }
      )

    send(self(), {:run_showcase, engine_facade, sample_input, demo_identity})
    {:ok, %{last_report: nil}}
  end

  @impl true
  def handle_call(:get_last_report, _from, state) do
    {:reply, state.last_report, state}
  end

  @impl true
  def handle_info({:run_showcase, engine_facade, sample_input, demo_identity}, state) do
    last_report = run_showcase_demo(engine_facade, sample_input, demo_identity)
    {:noreply, %{state | last_report: last_report}}
  end

  def handle_info(_unknown_message, state), do: {:noreply, state}

  defp run_showcase_demo(%EngineFacade{} = engine_facade, sample_input, demo_identity) do
    Logger.info("boxed_expression_showcase: starting CL3 expression showcase for #{@decision_model_id}")

    with :ok <- deploy_dmn_model(engine_facade),
         :ok <- deploy_bpmn_process(engine_facade),
         {:ok, process_version} <- fetch_latest_process_version(engine_facade),
         {:ok, process_run} <- start_process_run(engine_facade, process_version, sample_input, demo_identity),
         {:ok, process_trace} <- fetch_process_trace(engine_facade, process_run),
         {:ok, evaluation_result} <- evaluate_root_decision(engine_facade, sample_input),
         {:ok, ad_hoc_trace} <- trace_from_evaluation_result(evaluation_result) do
      process_report = ExpressionTypeReporter.build_report(process_trace)
      ad_hoc_report = ExpressionTypeReporter.build_report(ad_hoc_trace)

      log_report(:process, process_report)
      log_report(:ad_hoc, ad_hoc_report)

      %{
        process_trace: process_trace,
        ad_hoc_trace: ad_hoc_trace,
        process_report: process_report,
        ad_hoc_report: ad_hoc_report,
        evaluation_result: normalize_evaluation_snapshot(evaluation_result)
      }
    else
      {:error, reason} = error ->
        Logger.error("boxed_expression_showcase: showcase run failed: #{inspect(reason)}")
        error

      :deploy_aborted ->
        Logger.warning("boxed_expression_showcase: deploy aborted; skipping showcase")
        nil
    end
  end

  defp deploy_dmn_model(%EngineFacade{decisions: decisions}) do
    case decisions.deploy.([bundled_dmn_xml()]) do
      {:ok, _deploy_results} ->
        :ok

      {:error, :version_exists, _conflicts} ->
        Logger.info("boxed_expression_showcase: DMN version already deployed, continuing")
        :ok

      {:error, _reason_code, _details} = error ->
        Logger.error("boxed_expression_showcase: DMN deploy failed: #{inspect(error)}")
        :deploy_aborted

      {:error, reason} ->
        Logger.error("boxed_expression_showcase: DMN deploy failed: #{inspect(reason)}")
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
            Logger.info("boxed_expression_showcase: BPMN version already deployed, continuing")
            :ok

          {:error, reason} ->
            Logger.error("boxed_expression_showcase: BPMN deploy failed: #{inspect(reason)}")
            :deploy_aborted
        end

      {:error, reason} ->
        Logger.error("boxed_expression_showcase: BPMN parse failed: #{inspect(reason)}")
        {:error, {:parse_failed, reason}}
    end
  end

  defp fetch_latest_process_version(%EngineFacade{processes: processes}) do
    case processes.get_latest_version.(@process_model_id) do
      {:ok, process_version} -> {:ok, process_version}
      {:error, reason} -> {:error, {:get_latest_version_failed, reason}}
    end
  end

  defp start_process_run(
         %EngineFacade{processes: processes},
         process_version,
         sample_input,
         demo_identity
       ) do
    process_version_id = version_record_id(process_version)
    process_instance_id = generate_process_instance_identifier()

    start_arguments = [
      process_instance_id: process_instance_id,
      process_version_id: process_version_id,
      payload: sample_input,
      identity: demo_identity
    ]

    case processes.start.(start_arguments) do
      {:ok, _process_instance_pid} ->
        {:ok, %{process_instance_id: process_instance_id}}

      {:error, reason} ->
        {:error, {:start_process_instance_failed, reason}}
    end
  end

  defp fetch_process_trace(%EngineFacade{} = engine_facade, process_run) do
    Process.sleep(@fni_poll_delay_ms)

    case find_business_rule_fni(engine_facade.flow_node_instances, process_run.process_instance_id) do
      {:ok, flow_node_instance} ->
        case trace_from_flow_node_instance(flow_node_instance) do
          nil -> {:error, :process_trace_missing}
          trace -> {:ok, normalize_trace_for_reporter(trace)}
        end

      {:error, reason} ->
        Logger.warning(
          "boxed_expression_showcase: could not find BRT FNI for PI #{process_run.process_instance_id}: #{inspect(reason)}"
        )

        {:error, :process_trace_missing}
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

  defp evaluate_root_decision(%EngineFacade{decisions: decisions}, sample_input) do
    evaluate_options = [decision_model_id: @root_decision_element_id]

    case decisions.evaluate.(@decision_model_id, sample_input, evaluate_options) do
      {:ok, evaluation_result} -> {:ok, evaluation_result}
      {:error, reason} -> {:error, {:evaluate_failed, reason}}
    end
  end

  defp trace_from_evaluation_result(%EvaluationResult{} = evaluation_result) do
    case evaluation_result.trace do
      %{} = trace -> {:ok, normalize_trace_for_reporter(trace)}
      nil -> {:error, :evaluation_trace_missing}
    end
  end

  defp trace_from_evaluation_result(evaluation_snapshot) when is_map(evaluation_snapshot) do
    trace =
      Map.get(evaluation_snapshot, :trace) || Map.get(evaluation_snapshot, "trace")

    if is_map(trace) do
      {:ok, normalize_trace_for_reporter(trace)}
    else
      {:error, :evaluation_trace_missing}
    end
  end

  defp trace_from_flow_node_instance(flow_node_instance) when is_map(flow_node_instance) do
    type_properties =
      Map.get(flow_node_instance, :type_properties) ||
        Map.get(flow_node_instance, "typeProperties", %{})

    Map.get(type_properties, :trace) || Map.get(type_properties, "trace")
  end

  defp trace_from_flow_node_instance(_invalid), do: nil

  defp normalize_trace_for_reporter(trace) when is_map(trace) do
    decisions =
      trace
      |> map_value(:decisions, [])
      |> Enum.map(&normalize_decision_trace/1)

    %{"decisions" => decisions}
  end

  defp normalize_decision_trace(decision) when is_map(decision) do
    %{
      "decision_name" =>
        map_value(decision, :decision_name, nil) || map_value(decision, :name, nil),
      "hit_policy" => normalize_hit_policy(map_value(decision, :hit_policy, nil)),
      "result" => map_value(decision, :result, nil),
      "duration_microseconds" => map_value(decision, :duration_microseconds, 0)
    }
  end

  defp normalize_hit_policy(nil), do: nil
  defp normalize_hit_policy(hit_policy) when is_atom(hit_policy), do: hit_policy

  defp normalize_hit_policy(hit_policy) when is_binary(hit_policy) do
    try do
      String.to_existing_atom(hit_policy)
    rescue
      ArgumentError -> hit_policy
    end
  end

  defp normalize_evaluation_snapshot(%EvaluationResult{} = evaluation_result) do
    %{
      result: evaluation_result.result,
      hit_policy: evaluation_result.hit_policy,
      decision_name: evaluation_result.decision_name
    }
  end

  defp normalize_evaluation_snapshot(evaluation_snapshot) when is_map(evaluation_snapshot) do
    %{
      result: Map.get(evaluation_snapshot, :result) || Map.get(evaluation_snapshot, "result"),
      hit_policy:
        Map.get(evaluation_snapshot, :hit_policy) || Map.get(evaluation_snapshot, "hitPolicy"),
      decision_name:
        Map.get(evaluation_snapshot, :decision_name) ||
          Map.get(evaluation_snapshot, "decisionName")
    }
  end

  defp map_value(map, key, default) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key)) || default
  end

  defp pick_executable_process!(%Definitions{processes: processes}) do
    case Enum.find(processes, & &1.is_executable) do
      %EvilEngine.BPMN.Model.Process{} = process -> process
      nil -> raise ArgumentError, "boxed_expression_showcase example requires an executable process"
    end
  end

  defp version_record_id(process_version) when is_map(process_version) do
    Map.get(process_version, :id) || Map.get(process_version, "id")
  end

  defp generate_process_instance_identifier do
    random_bytes = :crypto.strong_rand_bytes(16)
    "pi-" <> Base.encode16(random_bytes, case: :lower)
  end

  defp log_report(source, report) when is_list(report) do
    Logger.info(
      "boxed_expression_showcase: #{source} report decisions=#{length(report)} expression_types=#{length(ExpressionTypeReporter.all_expression_types())}"
    )

    Enum.each(report, fn entry ->
      Logger.info(
        "boxed_expression_showcase: #{source} #{entry.decision} type=#{entry.expression_type} duration_us=#{entry.duration_us}"
      )
    end)
  end

  defp bundled_dmn_xml do
    [__DIR__, "..", "dmn", "expression_showcase.dmn"]
    |> Path.join()
    |> Path.expand()
    |> File.read!()
  end

  defp bundled_bpmn_xml do
    [__DIR__, "..", "bpmn", "showcase_runner_process.bpmn"]
    |> Path.join()
    |> Path.expand()
    |> File.read!()
  end
end
