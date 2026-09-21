defmodule Examples.BusinessRules.DecisionServiceSmokeTester.SmokeTesterWorker do
  @moduledoc """
  GenServer that enumerates deployed DMN models, discovers Decision Services,
  evaluates each with registry fixtures, and logs a structured health report.
  """

  use GenServer

  require Logger

  alias BfwEngine.DMN.ServiceEvaluationResult
  alias BfwEngine.EngineFacade
  alias Examples.BusinessRules.DecisionServiceSmokeTester.{
    HealthReporter,
    ServiceDiscoverer,
    TestInputRegistry
  }

  @doc "Starts the worker and schedules the Decision Service smoke test run."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) do
    GenServer.start_link(__MODULE__, options)
  end

  @doc "Returns the last health report produced by this worker, if any."
  @spec get_last_report(GenServer.server()) :: map() | nil
  def get_last_report(worker_pid) do
    GenServer.call(worker_pid, :get_last_report)
  end

  @impl true
  def init(options) do
    engine_facade = Keyword.fetch!(options, :facade)
    send(self(), {:run_smoke_tests, engine_facade})
    {:ok, %{last_report: nil}}
  end

  @impl true
  def handle_call(:get_last_report, _from, state) do
    {:reply, state.last_report, state}
  end

  @impl true
  def handle_info({:run_smoke_tests, engine_facade}, state) do
    last_report = run_smoke_tests(engine_facade)
    {:noreply, %{state | last_report: last_report}}
  end

  def handle_info(_unknown_message, state), do: {:noreply, state}

  defp run_smoke_tests(%EngineFacade{} = engine_facade) do
    Logger.info("decision_service_smoke_tester: starting Decision Service health check")

    test_results = collect_test_results(engine_facade)
    report = HealthReporter.build(test_results)
    log_report(report)
    report
  end

  defp collect_test_results(%EngineFacade{decisions: decisions}) do
    case decisions.list.() do
      {:ok, definitions} ->
        Enum.flat_map(definitions, fn definition ->
          model_id = definition_model_id(definition)
          collect_results_for_model(decisions, model_id)
        end)

      {:error, reason} ->
        Logger.error("decision_service_smoke_tester: list failed: #{inspect(reason)}")
        []

      definitions when is_list(definitions) ->
        Enum.flat_map(definitions, fn definition ->
          model_id = definition_model_id(definition)
          collect_results_for_model(decisions, model_id)
        end)
    end
  end

  defp collect_results_for_model(decisions, model_id) do
    case decisions.get_xml.(model_id) do
      {:ok, dmn_xml} ->
        service_ids = ServiceDiscoverer.discover(dmn_xml)

        Enum.map(service_ids, fn service_id ->
          test_input = TestInputRegistry.get(model_id, service_id)
          outcome = evaluate_service(decisions, model_id, service_id, test_input)

          %{model_id: model_id, service_id: service_id, outcome: outcome}
        end)

      {:error, reason} ->
        Logger.warning(
          "decision_service_smoke_tester: get_xml failed for #{model_id}: #{inspect(reason)}"
        )

        []
    end
  end

  defp evaluate_service(decisions, model_id, service_id, test_input) do
    case decisions.evaluate_service.(model_id, service_id, test_input, []) do
      {:ok, %ServiceEvaluationResult{} = result} ->
        {:ok, result}

      {:ok, result} when is_map(result) ->
        {:ok, result}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp definition_model_id(definition) do
    case definition do
      %{decision_definition_id: model_id} when is_binary(model_id) ->
        model_id

      %{"decisionDefinitionId" => model_id} when is_binary(model_id) ->
        model_id

      %{id: model_id} when is_binary(model_id) ->
        model_id

      _other ->
        ""
    end
  end

  defp log_report(report) when is_map(report) do
    Logger.info(
      "decision_service_smoke_tester: report models=#{report.total_models} services=#{report.total_services} healthy=#{report.healthy} unhealthy=#{report.unhealthy}"
    )

    Enum.each(report.details, fn detail ->
      case detail.status do
        :healthy ->
          Logger.info(
            "decision_service_smoke_tester: healthy model=#{detail.model_id} service=#{detail.service_id} duration_us=#{detail.duration_us} shape=#{inspect(detail.result_shape)}"
          )

        :unhealthy ->
          Logger.warning(
            "decision_service_smoke_tester: unhealthy model=#{detail.model_id} service=#{detail.service_id} error=#{inspect(detail.error)}"
          )
      end
    end)
  end
end
