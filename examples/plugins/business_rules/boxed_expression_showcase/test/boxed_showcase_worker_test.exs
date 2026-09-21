defmodule Examples.BusinessRules.BoxedExpressionShowcase.BoxedShowcaseWorkerTest do
  use ExUnit.Case

  alias BfwEngine.EngineFacade
  alias Examples.BusinessRules.BoxedExpressionShowcase.BoxedShowcaseWorker

  @process_version_id "process-version-showcase"
  @sample_input %{
    "baseSalary" => 75_000,
    "department" => "engineering",
    "performanceRating" => 4,
    "yearsOfService" => 8,
    "certifications" => ["AWS", "PMP"]
  }

  defp full_showcase_trace do
    %{
      "decisions" => [
        %{"decision_name" => "Department Multiplier", "hit_policy" => :unique, "result" => 1.15, "duration_microseconds" => 10},
        %{"decision_name" => "Performance Bonus", "hit_policy" => nil, "result" => 4_000, "duration_microseconds" => 12},
        %{"decision_name" => "Certification Allowance", "hit_policy" => nil, "result" => [2000, 3000, 0, 0], "duration_microseconds" => 14},
        %{"decision_name" => "Certification Total", "hit_policy" => nil, "result" => 5000, "duration_microseconds" => 8},
        %{"decision_name" => "Benefits Package", "hit_policy" => nil, "result" => %{"healthTier" => "standard"}, "duration_microseconds" => 16},
        %{"decision_name" => "Salary Bands", "hit_policy" => nil, "result" => [], "duration_microseconds" => 9},
        %{"decision_name" => "Eligible for Promotion", "hit_policy" => nil, "result" => true, "duration_microseconds" => 7},
        %{"decision_name" => "Qualified Certifications", "hit_policy" => nil, "result" => ["AWS", "PMP"], "duration_microseconds" => 11},
        %{"decision_name" => "Certification Details", "hit_policy" => nil, "result" => [], "duration_microseconds" => 13},
        %{"decision_name" => "All Certs Premium", "hit_policy" => nil, "result" => false, "duration_microseconds" => 6},
        %{"decision_name" => "Has Premium Cert", "hit_policy" => nil, "result" => false, "duration_microseconds" => 5},
        %{"decision_name" => "Total Compensation", "hit_policy" => nil, "result" => 104_250, "duration_microseconds" => 20}
      ]
    }
  end

  defp build_stub_facade(calls_agent) do
    append_event = fn event ->
      Agent.update(calls_agent, fn events -> events ++ [event] end)
    end

    deploy_count = :atomics.new(1, signed: false)

    %EngineFacade{
      engine_id: "test-engine-id",
      engine_name: "test-engine-name",
      version: "0.0.0-test",
      decisions: %EngineFacade.Decisions{
        deploy: fn _sources ->
          :atomics.add(deploy_count, 1, 1)
          append_event.(:dmn_deploy)

          case :atomics.get(deploy_count, 1) do
            1 -> {:ok, [%{decision_definition_id: "expression-showcase", version: "1.0.0"}]}
            2 -> {:error, :version_exists, [%{version: "1.0.0"}]}
            _ -> {:error, :unexpected}
          end
        end,
        evaluate: fn "expression-showcase", input, options ->
          append_event.({:evaluate, input, options})

          {:ok,
           %{
             result: 104_250,
             hit_policy: nil,
             decision_name: "Total Compensation",
             trace: full_showcase_trace()
           }}
        end
      },
      processes: %EngineFacade.Processes{
        deploy: fn _batch ->
          append_event.(:bpmn_deploy)
          {:ok, [%{process_model_id: "showcase-runner-process", version: "1.0.0"}]}
        end,
        get_latest_version: fn "showcase-runner-process" ->
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
               flow_node_id: "BRT_calculate_compensation",
               type_properties: %{trace: full_showcase_trace()}
             }
           ]}
        end
      }
    }
  end

  test "worker deploys DMN and BPMN, starts process, collects trace, and builds report" do
    {:ok, calls_agent} = Agent.start_link(fn -> [] end)
    facade = build_stub_facade(calls_agent)

    {:ok, worker_pid} = BoxedShowcaseWorker.start_link(facade: facade, sample_input: @sample_input)

    Process.sleep(250)

    events = Agent.get(calls_agent, & &1)
    result = BoxedShowcaseWorker.get_last_report(worker_pid)

    assert :dmn_deploy in events
    assert :bpmn_deploy in events
    assert :get_latest_version in events
    assert Enum.any?(events, &match?({:start, _}, &1))
    assert Enum.any?(events, &match?({:list_fnis, _}, &1))
    assert Enum.any?(events, fn
           {:evaluate, input, _options} -> input == @sample_input
           _event -> false
         end)

    assert length(result.process_report) == 12
    assert length(result.ad_hoc_report) == 12
    assert result.evaluation_result.result == 104_250

    total_entry = Enum.find(result.ad_hoc_report, &(&1.decision == "Total Compensation"))
    assert total_entry.expression_type == :literal_expression
    assert total_entry.result == 104_250

    GenServer.stop(worker_pid, :normal, 5_000)
  end

  test "ad-hoc evaluate trace is processed by ExpressionTypeReporter" do
    {:ok, calls_agent} = Agent.start_link(fn -> [] end)
    facade = build_stub_facade(calls_agent)

    {:ok, worker_pid} = BoxedShowcaseWorker.start_link(facade: facade)

    Process.sleep(250)

    result = BoxedShowcaseWorker.get_last_report(worker_pid)

    assert Enum.all?(result.ad_hoc_report, fn entry ->
             entry.expression_type != :unknown
           end)

    GenServer.stop(worker_pid, :normal, 5_000)
  end

  test "worker handles deploy failure" do
    facade = %EngineFacade{
      engine_id: "test-engine-id",
      engine_name: "test-engine-name",
      version: "0.0.0-test",
      decisions: %EngineFacade.Decisions{
        deploy: fn _sources -> {:error, :parse_error, "invalid xml"} end
      },
      processes: %EngineFacade.Processes{
        deploy: fn _batch -> {:ok, []} end
      }
    }

    {:ok, worker_pid} = BoxedShowcaseWorker.start_link(facade: facade)

    Process.sleep(150)

    assert BoxedShowcaseWorker.get_last_report(worker_pid) == nil

    GenServer.stop(worker_pid, :normal, 5_000)
  end
end
