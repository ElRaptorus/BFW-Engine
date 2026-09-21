defmodule Examples.BusinessRules.DecisionAuditReporter.AuditReporterWorkerTest do
  use ExUnit.Case, async: false

  alias BfwEngine.EngineFacade
  alias Examples.BusinessRules.DecisionAuditReporter.AuditReporterWorker
  alias Examples.BusinessRules.DecisionAuditReporter.EventTracker

  test "worker inspects tracked FNIs, runs boundary tests, and builds a report" do
    tracker_name = :"audit_worker_tracker_#{:erlang.unique_integer([:positive])}"
    {:ok, _pid} = EventTracker.start_link(name: tracker_name)

    :ok =
      EventTracker.track(
        %{
          flow_node_instance_id: "fni-1",
          process_instance_id: "process-instance-1",
          flow_node_id: "BRT_determine_benefits"
        },
        name: tracker_name
      )

    {:ok, calls_agent} = Agent.start_link(fn -> [] end)

    facade = %EngineFacade{
      engine_id: "test-engine-id",
      engine_name: "test-engine-name",
      version: "0.0.0-test",
      flow_node_instances: %EngineFacade.FlowNodeInstances{
        get: fn flow_node_instance_id ->
          Agent.update(calls_agent, fn events -> [{:get, flow_node_instance_id} | events] end)

          {:ok,
           %{
             type_properties: %{
               "decision_ref" => "employee-benefits",
               "duration_us" => 12_000,
               "matched_rules" => ["rule_1", "rule_2"]
             }
           }}
        end
      },
      decisions: %EngineFacade.Decisions{
        evaluate: fn decision_ref, input, _options ->
          Agent.update(calls_agent, fn events ->
            [{:evaluate, decision_ref, input} | events]
          end)

          {:ok, %{result: %{"tier" => "bronze"}}}
        end
      }
    }

    {:ok, worker_pid} =
      AuditReporterWorker.start_link(
        facade: facade,
        tracker_name: tracker_name,
        collection_window_ms: 0
      )

    report =
      Enum.reduce_while(1..40, nil, fn _attempt, _acc ->
        case AuditReporterWorker.get_last_report(worker_pid) do
          nil ->
            Process.sleep(25)
            {:cont, nil}

          built_report ->
            {:halt, built_report}
        end
      end)
    events = Agent.get(calls_agent, & &1)

    assert is_map(report)
    assert {:get, "fni-1"} in events
    assert Enum.count(events, &match?({:evaluate, "employee-benefits", _}, &1)) == 7

    assert report.summary.total_decision_executions == 1
    assert hd(report.per_model).decision_ref == "employee-benefits"
    assert "rule_10" in hd(report.per_model).rule_coverage.dead_rules
    refute report.compliance.no_dead_rules_found

    GenServer.stop(worker_pid)
    Agent.stop(tracker_name)
  end
end
