defmodule Examples.BusinessRules.DrdChainOrchestrator.DrdChainOrchestratorWorkerTest do
  use ExUnit.Case

  alias BfwEngine.EngineFacade
  alias Examples.BusinessRules.DrdChainOrchestrator.DrdChainOrchestratorWorker

  @process_version_id "process-version-credit-underwriting"
  @root_decision_element_id "Decision_underwriting_decision"

  defp sample_trace do
    %{
      "decisions" => [
        %{
          "decision_name" => "Applicant Credit Score",
          "hit_policy" => "unique",
          "result" => 720,
          "duration_microseconds" => 1_200,
          "bkm_traces" => [
            %{
              "bkm_name" => "Credit Score Calculator",
              "formal_parameters" => [
                %{"name" => "creditHistory", "bound_value" => "good"}
              ],
              "result" => 720,
              "dependent_bkm_traces" => []
            }
          ],
          "inputs" => [%{}, %{}]
        },
        %{
          "decision_name" => "Debt-to-Income Ratio",
          "hit_policy" => "unique",
          "result" => 0.2,
          "duration_microseconds" => 80,
          "inputs" => [%{}]
        },
        %{
          "decision_name" => "Risk Assessment",
          "hit_policy" => "first",
          "result" => %{"riskLevel" => "moderate_low"},
          "duration_microseconds" => 450,
          "inputs" => [%{}, %{}]
        },
        %{
          "decision_name" => "Underwriting Decision",
          "hit_policy" => "unique",
          "result" => %{"approved" => true, "approvedAmount" => 300_000},
          "duration_microseconds" => 900,
          "inputs" => [%{}, %{}]
        }
      ]
    }
  end

  defp build_stub_facade(calls_agent) do
    append_event = fn event ->
      Agent.update(calls_agent, fn events -> events ++ [event] end)
    end

    %EngineFacade{
      engine_id: "test-engine-id",
      engine_name: "test-engine-name",
      version: "0.0.0-test",
      decisions: %EngineFacade.Decisions{
        deploy: fn _sources ->
          append_event.(:dmn_deploy)
          {:ok, [%{decision_definition_id: "credit-underwriting", version: "1.0.0"}]}
        end,
        evaluate: fn "credit-underwriting", _input, options ->
          append_event.({:evaluate, options})

          {:ok,
           %{
             trace: sample_trace(),
             result: %{"approved" => true, "approvedAmount" => 300_000},
             hit_policy: :unique
           }}
        end
      },
      processes: %EngineFacade.Processes{
        deploy: fn _batch ->
          append_event.(:bpmn_deploy)
          {:ok, [%{process_model_id: "credit-underwriting-process", version: "1.0.0"}]}
        end,
        get_latest_version: fn "credit-underwriting-process" ->
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
        list_for_process_instance: fn process_instance_id ->
          append_event.({:list_fnis, process_instance_id})

          {:ok,
           [
             %{
               flow_node_id: "BRT_underwrite_application",
               type_properties: %{trace: sample_trace()}
             }
           ]}
        end
      }
    }
  end

  test "worker runs full orchestration deploy start list FNIs format trace flow" do
    {:ok, calls_agent} = Agent.start_link(fn -> [] end)
    facade = build_stub_facade(calls_agent)

    sample_input = %{
      "annualIncome" => 75_000,
      "creditHistory" => "good",
      "existingDebt" => 15_000,
      "requestedAmount" => 200_000
    }

    {:ok, worker_pid} =
      DrdChainOrchestratorWorker.start_link(facade: facade, sample_input: sample_input)

    Process.sleep(250)

    events = Agent.get(calls_agent, & &1)
    report = DrdChainOrchestratorWorker.get_last_report(worker_pid)

    assert :dmn_deploy in events
    assert :bpmn_deploy in events
    assert :get_latest_version in events
    assert Enum.any?(events, &match?({:start, _}, &1))
    assert Enum.any?(events, &match?({:list_fnis, _}, &1))
    assert Enum.any?(events, &match?({:evaluate, _}, &1))

    assert report.decision_count == 4
    assert length(report.business_rule_chain) == 4
    assert report.chains_match == true
    assert hd(report.business_rule_chain).decision == "Applicant Credit Score"
    assert report.business_rule_summary =~ "Applicant Credit Score"

    GenServer.stop(worker_pid, :normal, 5_000)
  end

  test "ad-hoc evaluate trace can be formatted and matches evaluate options" do
    {:ok, calls_agent} = Agent.start_link(fn -> [] end)

    evaluate_options_captured = :atomics.new(1, signed: false)

    facade = %EngineFacade{
      engine_id: "test-engine-id",
      engine_name: "test-engine-name",
      version: "0.0.0-test",
      decisions: %EngineFacade.Decisions{
        deploy: fn _sources -> {:ok, [%{version: "1.0.0"}]} end,
        evaluate: fn "credit-underwriting", _input, options ->
          :atomics.exchange(evaluate_options_captured, 1, 1)
          Agent.update(calls_agent, fn events -> events ++ [{:evaluate, options}] end)

          {:ok,
           %{
             trace: sample_trace(),
             result: %{"approved" => true},
             hit_policy: :unique
           }}
        end
      },
      processes: %EngineFacade.Processes{
        deploy: fn _batch -> {:ok, [%{process_model_id: "credit-underwriting-process"}]} end,
        get_latest_version: fn _model_id -> {:ok, %{id: @process_version_id}} end,
        start: fn start_arguments ->
          {:ok, Keyword.fetch!(start_arguments, :process_instance_id)}
        end
      },
      flow_node_instances: %EngineFacade.FlowNodeInstances{
        list_for_process_instance: fn _process_instance_id ->
          {:ok,
           [
             %{
               flow_node_id: "BRT_underwrite_application",
               type_properties: %{trace: sample_trace()}
             }
           ]}
        end
      }
    }

    {:ok, worker_pid} = DrdChainOrchestratorWorker.start_link(facade: facade)

    Process.sleep(250)

    events = Agent.get(calls_agent, & &1)
    {:evaluate, options} = Enum.find(events, &match?({:evaluate, _}, &1))

    assert Keyword.get(options, :decision_model_id) == @root_decision_element_id
    assert :atomics.get(evaluate_options_captured, 1) == 1

    GenServer.stop(worker_pid, :normal, 5_000)
  end

  test "worker handles deploy failure" do
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
          append_event.(:dmn_deploy_failed)
          {:error, :invalid_xml}
        end
      },
      processes: %EngineFacade.Processes{
        deploy: fn _batch -> {:ok, [%{process_model_id: "credit-underwriting-process"}]} end
      },
      flow_node_instances: %EngineFacade.FlowNodeInstances{
        list_for_process_instance: fn _process_instance_id -> {:ok, []} end
      }
    }

    {:ok, worker_pid} = DrdChainOrchestratorWorker.start_link(facade: facade)

    Process.sleep(250)

    events = Agent.get(calls_agent, & &1)
    report = DrdChainOrchestratorWorker.get_last_report(worker_pid)

    assert :dmn_deploy_failed in events
    refute :bpmn_deploy in events
    assert report == nil

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
        end,
        evaluate: fn "credit-underwriting", _input, _options ->
          {:ok, %{trace: sample_trace(), result: %{}, hit_policy: :unique}}
        end
      },
      processes: %EngineFacade.Processes{
        deploy: fn _batch ->
          append_event.(:bpmn_deploy_version_exists)
          {:error, :version_exists, [%{version: "1.0.0"}]}
        end,
        get_latest_version: fn "credit-underwriting-process" ->
          {:ok, %{id: @process_version_id, version: "1.0.0"}}
        end,
        start: fn start_arguments ->
          {:ok, Keyword.fetch!(start_arguments, :process_instance_id)}
        end
      },
      flow_node_instances: %EngineFacade.FlowNodeInstances{
        list_for_process_instance: fn _process_instance_id ->
          {:ok,
           [
             %{
               flow_node_id: "BRT_underwrite_application",
               type_properties: %{trace: sample_trace()}
             }
           ]}
        end
      }
    }

    {:ok, worker_pid} = DrdChainOrchestratorWorker.start_link(facade: facade)

    Process.sleep(250)

    events = Agent.get(calls_agent, & &1)
    report = DrdChainOrchestratorWorker.get_last_report(worker_pid)

    assert :dmn_deploy_version_exists in events
    assert :bpmn_deploy_version_exists in events
    assert report.decision_count == 4

    GenServer.stop(worker_pid, :normal, 5_000)
  end
end
