defmodule Examples.BusinessRules.DecisionAuditReporter.AuditReporterWorker do
  @moduledoc """
  GenServer that waits for a collection window, inspects tracked Business Rule
  Task flow node instances through the facade, runs boundary evaluations, and
  logs a structured compliance audit report.
  """

  use GenServer

  require Logger

  alias EvilEngine.EngineFacade
  alias Examples.BusinessRules.DecisionAuditReporter.AuditReportBuilder
  alias Examples.BusinessRules.DecisionAuditReporter.BoundaryTester
  alias Examples.BusinessRules.DecisionAuditReporter.EventTracker
  alias Examples.BusinessRules.DecisionAuditReporter.FniInspector

  @decision_model_id "employee-benefits"
  @default_collection_window_ms 60_000

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

  @employee_benefits_boundary_inputs [
    %{
      test_case: "platinum_outstanding_25y",
      input: %{
        "yearsOfService" => 25,
        "department" => "engineering",
        "performanceRating" => "outstanding",
        "employeeType" => "full_time"
      }
    },
    %{
      test_case: "gold_outstanding_12y",
      input: %{
        "yearsOfService" => 12,
        "department" => "sales",
        "performanceRating" => "outstanding",
        "employeeType" => "full_time"
      }
    },
    %{
      test_case: "gold_exceeds_15y",
      input: %{
        "yearsOfService" => 15,
        "department" => "marketing",
        "performanceRating" => "exceeds",
        "employeeType" => "full_time"
      }
    },
    %{
      test_case: "silver_meets_7y",
      input: %{
        "yearsOfService" => 7,
        "department" => "support",
        "performanceRating" => "meets",
        "employeeType" => "full_time"
      }
    },
    %{
      test_case: "executive_department",
      input: %{
        "yearsOfService" => 0,
        "department" => "executive",
        "performanceRating" => "meets",
        "employeeType" => "full_time"
      }
    },
    %{
      test_case: "part_time",
      input: %{
        "yearsOfService" => 3,
        "department" => "support",
        "performanceRating" => "meets",
        "employeeType" => "part_time"
      }
    },
    %{
      test_case: "contractor",
      input: %{
        "yearsOfService" => 1,
        "department" => "engineering",
        "performanceRating" => "meets",
        "employeeType" => "contractor"
      }
    }
  ]

  @doc "Starts the worker. Options: `:facade`, `:tracker_name`, `:collection_window_ms`."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) do
    GenServer.start_link(__MODULE__, options)
  end

  @doc "Returns the last audit report produced by this worker, if any."
  @spec get_last_report(GenServer.server()) :: map() | nil
  def get_last_report(worker_pid) do
    GenServer.call(worker_pid, :get_last_report)
  end

  @doc "Employee-benefits rule catalog used when that model appears in the window."
  @spec employee_benefits_rule_ids() :: [String.t()]
  def employee_benefits_rule_ids, do: @all_rule_ids

  @doc "Boundary-case inputs for `employee-benefits` ad-hoc evaluations."
  @spec employee_benefits_boundary_inputs() :: [map()]
  def employee_benefits_boundary_inputs, do: @employee_benefits_boundary_inputs

  @impl true
  def init(options) do
    engine_facade = Keyword.fetch!(options, :facade)
    tracker_name = Keyword.get(options, :tracker_name, EventTracker)

    collection_window_ms =
      Keyword.get(options, :collection_window_ms, @default_collection_window_ms)

    send(self(), {:run_audit, engine_facade, tracker_name, collection_window_ms})
    {:ok, %{last_report: nil}}
  end

  @impl true
  def handle_call(:get_last_report, _from, state) do
    {:reply, state.last_report, state}
  end

  @impl true
  def handle_info({:run_audit, engine_facade, tracker_name, collection_window_ms}, state) do
    if collection_window_ms > 0 do
      Process.sleep(collection_window_ms)
    end

    last_report = run_audit(engine_facade, tracker_name, collection_window_ms)
    {:noreply, %{state | last_report: last_report}}
  end

  def handle_info(_unknown_message, state), do: {:noreply, state}

  defp run_audit(%EngineFacade{} = engine_facade, tracker_name, collection_window_ms) do
    Logger.info("decision_audit_reporter: collecting Business Rule Task completions")

    flow_node_instance_ids =
      EventTracker.get_tracked_flow_node_instance_ids(name: tracker_name)

    flow_node_instance_details = FniInspector.fetch_all(engine_facade, flow_node_instance_ids)
    decision_models = extract_unique_decision_models(flow_node_instance_details)
    boundary_results = BoundaryTester.test_all(engine_facade, decision_models)

    all_rule_ids_by_model =
      Map.new(decision_models, fn model ->
        rule_ids =
          if model.decision_ref == @decision_model_id do
            @all_rule_ids
          else
            []
          end

        {model.decision_ref, rule_ids}
      end)

    report =
      AuditReportBuilder.build(%{
        collection_window_minutes: collection_window_ms / 60_000,
        flow_node_instance_details: flow_node_instance_details,
        boundary_results: boundary_results,
        all_rule_ids_by_model: all_rule_ids_by_model
      })

    log_report(report)
    report
  end

  defp extract_unique_decision_models(flow_node_instance_details) do
    flow_node_instance_details
    |> Enum.map(& &1.decision_ref)
    |> Enum.uniq()
    |> Enum.map(fn decision_ref ->
      boundary_inputs =
        if decision_ref == @decision_model_id do
          @employee_benefits_boundary_inputs
        else
          []
        end

      %{decision_ref: decision_ref, boundary_inputs: boundary_inputs}
    end)
  end

  defp log_report(report) when is_map(report) do
    Logger.info("decision_audit_reporter: #{Jason.encode!(report)}")
  end
end
