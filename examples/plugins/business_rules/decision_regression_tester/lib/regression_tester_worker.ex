defmodule Examples.BusinessRules.DecisionRegressionTester.RegressionTesterWorker do
  @moduledoc """
  GenServer that deploys two DMN tax-rate versions, evaluates fixture inputs against
  each version, and logs a structured regression diff report.
  """

  use GenServer

  require Logger

  alias EvilEngine.DMN.EvaluationResult
  alias EvilEngine.EngineFacade
  alias Examples.BusinessRules.DecisionRegressionTester.{
    RegressionComparator,
    TestInputs
  }

  @decision_model_id "tax-rates"
  @decision_element_id "Decision_tax_calculation"
  @version_one_string "1.0.0"
  @version_two_string "2.0.0"

  @doc "Starts the worker and schedules the bundled regression demo."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) do
    GenServer.start_link(__MODULE__, options)
  end

  @doc "Returns the last regression report produced by this worker, if any."
  @spec get_last_report(GenServer.server()) :: map() | nil
  def get_last_report(worker_pid) do
    GenServer.call(worker_pid, :get_last_report)
  end

  @impl true
  def init(options) do
    engine_facade = Keyword.fetch!(options, :facade)

    test_inputs =
      Keyword.get(options, :test_inputs, TestInputs.all())

    send(self(), {:run_regression, engine_facade, test_inputs})
    {:ok, %{last_report: nil}}
  end

  @impl true
  def handle_call(:get_last_report, _from, state) do
    {:reply, state.last_report, state}
  end

  @impl true
  def handle_info({:run_regression, engine_facade, test_inputs}, state) do
    last_report = run_regression_demo(engine_facade, test_inputs)
    {:noreply, %{state | last_report: last_report}}
  end

  def handle_info(_unknown_message, state), do: {:noreply, state}

  defp run_regression_demo(%EngineFacade{} = engine_facade, test_inputs) do
    Logger.info("decision_regression_tester: starting version comparison for #{@decision_model_id}")

    with :ok <- deploy_dmn_version(engine_facade, bundled_dmn_xml("tax_rates_v1.dmn")),
         :ok <- deploy_dmn_version(engine_facade, bundled_dmn_xml("tax_rates_v2.dmn")),
         {:ok, version_one_id, version_two_id} <- resolve_version_ids(engine_facade),
         {:ok, comparisons} <- compare_all_inputs(engine_facade, test_inputs, version_one_id, version_two_id) do
      report = RegressionComparator.build_report(comparisons)
      log_report(report)
      report
    else
      {:error, reason} = error ->
        Logger.error("decision_regression_tester: regression run failed: #{inspect(reason)}")
        error

      :deploy_aborted ->
        Logger.warning("decision_regression_tester: deploy aborted; skipping comparison")
        nil
    end
  end

  defp deploy_dmn_version(%EngineFacade{decisions: decisions}, dmn_xml) do
    case decisions.deploy.([dmn_xml]) do
      {:ok, _deploy_results} ->
        :ok

      {:error, :version_exists, _conflicts} ->
        Logger.info("decision_regression_tester: DMN version already deployed, continuing")
        :ok

      {:error, reason} ->
        Logger.error("decision_regression_tester: deploy failed: #{inspect(reason)}")
        :deploy_aborted
    end
  end

  defp resolve_version_ids(%EngineFacade{decisions: decisions}) do
    case decisions.get_versions.(@decision_model_id) do
      {:ok, versions} ->
        version_one_id = find_version_id(versions, @version_one_string)
        version_two_id = find_version_id(versions, @version_two_string)

        if is_binary(version_one_id) and is_binary(version_two_id) do
          {:ok, version_one_id, version_two_id}
        else
          {:error, {:missing_versions, version_one_id: version_one_id, version_two_id: version_two_id}}
        end

      {:error, reason} ->
        {:error, {:get_versions_failed, reason}}
    end
  end

  defp find_version_id(versions, version_string) do
    versions
    |> Enum.find_value(fn version_record ->
      version_value = Map.get(version_record, :version) || Map.get(version_record, "version")

      if version_value == version_string do
        Map.get(version_record, :id) || Map.get(version_record, "id")
      end
    end)
  end

  defp compare_all_inputs(_engine_facade, [], _version_one_id, _version_two_id) do
    {:ok, []}
  end

  defp compare_all_inputs(
         %EngineFacade{decisions: decisions},
         test_inputs,
         version_one_id,
         version_two_id
       ) do
    comparisons =
      Enum.map(test_inputs, fn input ->
        with {:ok, result_v1} <-
               evaluate_for_version(decisions, input, version_one_id),
             {:ok, result_v2} <-
               evaluate_for_version(decisions, input, version_two_id) do
          RegressionComparator.compare(
            normalize_evaluation_snapshot(result_v1),
            normalize_evaluation_snapshot(result_v2),
            input
          )
        end
      end)

    case Enum.find(comparisons, &match?({:error, _}, &1)) do
      {:error, reason} -> {:error, {:evaluate_failed, reason}}
      nil -> {:ok, comparisons}
    end
  end

  defp evaluate_for_version(decisions, input, decision_version_id) do
    evaluate_options = [
      decision_model_id: @decision_element_id,
      decision_version_id: decision_version_id
    ]

    decisions.evaluate.(@decision_model_id, input, evaluate_options)
  end

  defp normalize_evaluation_snapshot(%EvaluationResult{} = evaluation_result) do
    %{
      result: evaluation_result.result,
      matched_rules: evaluation_result.matched_rules,
      hit_policy: evaluation_result.hit_policy
    }
  end

  defp normalize_evaluation_snapshot(evaluation_snapshot) when is_map(evaluation_snapshot) do
    %{
      result: Map.get(evaluation_snapshot, :result) || Map.get(evaluation_snapshot, "result"),
      matched_rules:
        Map.get(evaluation_snapshot, :matched_rules) ||
          Map.get(evaluation_snapshot, "matchedRules", []),
      hit_policy:
        Map.get(evaluation_snapshot, :hit_policy) || Map.get(evaluation_snapshot, "hitPolicy")
    }
  end

  defp log_report(report) when is_map(report) do
    Logger.info(
      "decision_regression_tester: report total=#{report.total_inputs} identical=#{report.identical} diverged=#{report.diverged} regression_detected=#{report.regression_detected}"
    )

    Enum.each(report.details, fn divergence ->
      Logger.warning(
        "decision_regression_tester: diverged input=#{inspect(divergence.input)} v1=#{inspect(divergence.v1)} v2=#{inspect(divergence.v2)}"
      )
    end)
  end

  defp bundled_dmn_xml(file_name) do
    [__DIR__, "..", "dmn", file_name]
    |> Path.join()
    |> Path.expand()
    |> File.read!()
  end
end
