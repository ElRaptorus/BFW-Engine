defmodule Examples.BusinessRules.DeadRuleDetector.DeadRuleDetectorWorkerTest do
  use ExUnit.Case

  alias EvilEngine.EngineFacade
  alias Examples.BusinessRules.DeadRuleDetector.DeadRuleDetectorWorker

  @process_version_id "process-version-employee-benefits"

  defp trace_for_rule_id(rule_id) do
    %{
      "decisions" => [
        %{
          "matched_rules" => [%{"rule_id" => rule_id}]
        }
      ]
    }
  end

  defp build_stub_facade(calls_agent) do
    {:ok, trace_index_agent} = Agent.start_link(fn -> %{} end)

    append_event = fn event ->
      Agent.update(calls_agent, fn events -> events ++ [event] end)
    end

    deploy_count = :atomics.new(1, signed: false)
    start_sequence = :atomics.new(1, signed: false)

    matched_rule_ids_by_run = ["rule_1", "rule_2", "rule_3", "rule_4", "rule_5", "rule_6", "rule_7", "rule_8", "rule_9"]

    %EngineFacade{
      engine_id: "test-engine-id",
      engine_name: "test-engine-name",
      version: "0.0.0-test",
      decisions: %EngineFacade.Decisions{
        deploy: fn _sources ->
          :atomics.add(deploy_count, 1, 1)
          append_event.(:dmn_deploy)

          case :atomics.get(deploy_count, 1) do
            1 -> {:ok, [%{decision_definition_id: "employee-benefits", version: "1.0.0"}]}
            2 -> {:error, :version_exists, [%{version: "1.0.0"}]}
            _ -> {:error, :unexpected}
          end
        end
      },
      processes: %EngineFacade.Processes{
        deploy: fn _batch ->
          append_event.(:bpmn_deploy)
          {:ok, [%{process_model_id: "employee-benefits-process", version: "1.0.0"}]}
        end,
        get_latest_version: fn "employee-benefits-process" ->
          append_event.(:get_latest_version)
          {:ok, %{id: @process_version_id, version: "1.0.0"}}
        end,
        start: fn start_arguments ->
          process_instance_id = Keyword.fetch!(start_arguments, :process_instance_id)
          :atomics.add(start_sequence, 1, 1)
          run_index = :atomics.get(start_sequence, 1)
          rule_id = Enum.at(matched_rule_ids_by_run, run_index - 1, "rule_1")

          Agent.update(trace_index_agent, fn index ->
            Map.put(index, process_instance_id, rule_id)
          end)

          append_event.({:start, process_instance_id})
          {:ok, "process-instance-pid"}
        end
      },
      flow_node_instances: %EngineFacade.FlowNodeInstances{
        list_for_process_instance: fn process_instance_id ->
          append_event.({:list_fnis, process_instance_id})

          rule_id =
            Agent.get(trace_index_agent, fn index ->
              Map.get(index, process_instance_id, "rule_1")
            end)

          {:ok,
           [
             %{
               flow_node_id: "BRT_determine_benefits",
               type_properties: %{trace: trace_for_rule_id(rule_id)}
             }
           ]}
        end
      }
    }
  end

  test "worker runs full orchestration deploy start collect analyze flow" do
    {:ok, calls_agent} = Agent.start_link(fn -> [] end)
    facade = build_stub_facade(calls_agent)

    test_payloads = [
      %{"yearsOfService" => 25, "department" => "engineering", "employeeType" => "full_time"},
      %{"yearsOfService" => 12, "department" => "sales", "employeeType" => "full_time"},
      %{"yearsOfService" => 7, "department" => "support", "employeeType" => "full_time"}
    ]

    {:ok, worker_pid} =
      DeadRuleDetectorWorker.start_link(
        facade: facade,
        test_payloads: test_payloads
      )

    Process.sleep(250)

    events = Agent.get(calls_agent, & &1)
    report = DeadRuleDetectorWorker.get_last_report(worker_pid)

    assert :dmn_deploy in events
    assert :bpmn_deploy in events
    assert :get_latest_version in events
    assert Enum.count(events, &match?({:start, _}, &1)) == 3
    assert Enum.count(events, &match?({:list_fnis, _}, &1)) == 3

    assert report.execution_count == 3
    assert report.dead_rule_count == 9
    assert "rule_10" in report.dead_rules
    assert "rule_11" in report.dead_rules
    assert "rule_12" in report.dead_rules
    assert report.coverage_percent < 100.0

    GenServer.stop(worker_pid, :normal, 5_000)
  end

  test "worker handles already deployed models gracefully" do
    {:ok, calls_agent} = Agent.start_link(fn -> [] end)

    append_event = fn event ->
      Agent.update(calls_agent, fn events -> events ++ [event] end)
    end

    facade = %EngineFacade{
      engine_id: "test-engine-id",
      engine_name: "test-engine-name",
      version: "0.0.0-test",
      decisions: %EngineFacade.Decisions{
        deploy: fn _sources ->
          append_event.(:dmn_deploy_version_exists)
          {:error, :version_exists, [%{version: "1.0.0"}]}
        end
      },
      processes: %EngineFacade.Processes{
        deploy: fn _batch ->
          append_event.(:bpmn_deploy_version_exists)
          {:error, :version_exists, [%{version: "1.0.0"}]}
        end,
        get_latest_version: fn "employee-benefits-process" ->
          append_event.(:get_latest_version)
          {:ok, %{id: @process_version_id, version: "1.0.0"}}
        end,
        start: fn start_arguments ->
          process_instance_id = Keyword.fetch!(start_arguments, :process_instance_id)
          append_event.({:start, process_instance_id})
          {:ok, "process-instance-pid"}
        end
      },
      flow_node_instances: %EngineFacade.FlowNodeInstances{
        list_for_process_instance: fn _process_instance_id ->
          {:ok,
           [
             %{
               flow_node_id: "BRT_determine_benefits",
               type_properties: %{trace: trace_for_rule_id("rule_9")}
             }
           ]}
        end
      }
    }

    {:ok, worker_pid} =
      DeadRuleDetectorWorker.start_link(
        facade: facade,
        test_payloads: [
          %{
            "yearsOfService" => 1,
            "department" => "engineering",
            "performanceRating" => "meets",
            "employeeType" => "contractor"
          }
        ]
      )

    Process.sleep(250)

    events = Agent.get(calls_agent, & &1)
    report = DeadRuleDetectorWorker.get_last_report(worker_pid)

    assert :dmn_deploy_version_exists in events
    assert :bpmn_deploy_version_exists in events
    assert :get_latest_version in events
    assert report.execution_count == 1
    assert is_map(report)
    assert report.dead_rule_count == 11

    GenServer.stop(worker_pid, :normal, 5_000)
  end

  test "empty test payload list starts no processes and yields empty trace report" do
    {:ok, calls_agent} = Agent.start_link(fn -> [] end)

    facade = %EngineFacade{
      engine_id: "test-engine-id",
      engine_name: "test-engine-name",
      version: "0.0.0-test",
      decisions: %EngineFacade.Decisions{
        deploy: fn _sources -> {:ok, [%{version: "1.0.0"}]} end
      },
      processes: %EngineFacade.Processes{
        deploy: fn _batch -> {:ok, [%{process_model_id: "employee-benefits-process"}]} end,
        get_latest_version: fn _model_id -> {:ok, %{id: @process_version_id}} end,
        start: fn _arguments ->
          Agent.update(calls_agent, fn events -> events ++ [:unexpected_start] end)
          {:ok, "process-instance-pid"}
        end
      },
      flow_node_instances: %EngineFacade.FlowNodeInstances{
        list_for_process_instance: fn _process_instance_id -> {:ok, []} end
      }
    }

    {:ok, worker_pid} = DeadRuleDetectorWorker.start_link(facade: facade, test_payloads: [])

    Process.sleep(250)

    events = Agent.get(calls_agent, & &1)
    report = DeadRuleDetectorWorker.get_last_report(worker_pid)

    refute :unexpected_start in events
    assert report.execution_count == 0
    assert report.dead_rule_count == 12
    assert report.coverage_percent == 0.0

    GenServer.stop(worker_pid, :normal, 5_000)
  end
end
