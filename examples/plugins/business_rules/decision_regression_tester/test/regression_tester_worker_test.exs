defmodule Examples.BusinessRules.DecisionRegressionTester.RegressionTesterWorkerTest do
  use ExUnit.Case

  alias EvilEngine.EngineFacade
  alias Examples.BusinessRules.DecisionRegressionTester.RegressionTesterWorker

  @version_one_id "decision-version-v1"
  @version_two_id "decision-version-v2"

  test "worker deploys both versions, evaluates test inputs, and produces a report" do
    {:ok, calls_agent} = Agent.start_link(fn -> [] end)

    append_event = fn event ->
      Agent.update(calls_agent, fn events -> events ++ [event] end)
    end

    evaluate_count = :atomics.new(1, signed: false)

    facade = %EngineFacade{
      engine_id: "test-engine-id",
      engine_name: "test-engine-name",
      version: "0.0.0-test",
      decisions: %EngineFacade.Decisions{
        deploy: fn _sources ->
          append_event.(:deploy)
          {:ok, [%{decision_definition_id: "tax-rates", version: "1.0.0"}]}
        end,
        get_versions: fn "tax-rates" ->
          append_event.(:get_versions)
          {:ok,
           [
             %{id: @version_one_id, version: "1.0.0"},
             %{id: @version_two_id, version: "2.0.0"}
           ]}
        end,
        evaluate: fn "tax-rates", _input, options ->
          :atomics.add(evaluate_count, 1, 1)
          append_event.({:evaluate, Keyword.get(options, :decision_version_id)})

          version_id = Keyword.get(options, :decision_version_id)

          result =
            if version_id == @version_one_id do
              %{
                result: %{"bracket" => "low", "taxRate" => 0.15},
                matched_rules: ["Rule_single_low"],
                hit_policy: :first
              }
            else
              %{
                result: %{"bracket" => "low", "taxRate" => 0.12},
                matched_rules: ["Rule_single_low_v2"],
                hit_policy: :first
              }
            end

          {:ok, result}
        end
      }
    }

    test_inputs = [
      %{"annualIncome" => 25_000, "filingStatus" => "single"},
      %{"annualIncome" => 50_000, "filingStatus" => "single"}
    ]

    {:ok, worker_pid} = RegressionTesterWorker.start_link(facade: facade, test_inputs: test_inputs)

    Process.sleep(150)

    events = Agent.get(calls_agent, & &1)
    report = RegressionTesterWorker.get_last_report(worker_pid)

    assert Enum.count(events, &(&1 == :deploy)) == 2
    assert :get_versions in events
    assert :atomics.get(evaluate_count, 1) == 4

    assert report.total_inputs == 2
    assert report.regression_detected == true
    assert report.diverged == 2
    assert length(report.details) == 2

    GenServer.stop(worker_pid, :normal, 5_000)
  end

  test "worker handles deploy failure for version already existing" do
    {:ok, calls_agent} = Agent.start_link(fn -> [] end)

    append_event = fn event ->
      Agent.update(calls_agent, fn events -> events ++ [event] end)
    end

    deploy_count = :atomics.new(1, signed: false)

    facade = %EngineFacade{
      engine_id: "test-engine-id",
      engine_name: "test-engine-name",
      version: "0.0.0-test",
      decisions: %EngineFacade.Decisions{
        deploy: fn _sources ->
          :atomics.add(deploy_count, 1, 1)

          case :atomics.get(deploy_count, 1) do
            1 ->
              append_event.(:deploy_ok)
              {:ok, [%{version: "1.0.0"}]}

            2 ->
              append_event.(:deploy_version_exists)
              {:error, :version_exists, [%{version: "2.0.0"}]}

            _ ->
              {:error, :unexpected}
          end
        end,
        get_versions: fn "tax-rates" ->
          append_event.(:get_versions)
          {:ok,
           [
             %{id: @version_one_id, version: "1.0.0"},
             %{id: @version_two_id, version: "2.0.0"}
           ]}
        end,
        evaluate: fn "tax-rates", _input, _options ->
          {:ok,
           %{
             result: %{"taxRate" => 0.0},
             matched_rules: [],
             hit_policy: :first
           }}
        end
      }
    }

    {:ok, worker_pid} =
      RegressionTesterWorker.start_link(
        facade: facade,
        test_inputs: [%{"annualIncome" => 10_000, "filingStatus" => "single"}]
      )

    Process.sleep(150)

    events = Agent.get(calls_agent, & &1)
    report = RegressionTesterWorker.get_last_report(worker_pid)

    assert :deploy_ok in events
    assert :deploy_version_exists in events
    assert :get_versions in events
    assert report.regression_detected == false
    assert report.total_inputs == 1

    GenServer.stop(worker_pid, :normal, 5_000)
  end

  test "worker handles empty test input set" do
    facade = %EngineFacade{
      engine_id: "test-engine-id",
      engine_name: "test-engine-name",
      version: "0.0.0-test",
      decisions: %EngineFacade.Decisions{
        deploy: fn _sources -> {:ok, [%{version: "1.0.0"}]} end,
        get_versions: fn "tax-rates" ->
          {:ok,
           [
             %{id: @version_one_id, version: "1.0.0"},
             %{id: @version_two_id, version: "2.0.0"}
           ]}
        end,
        evaluate: fn _, _, _ -> {:ok, %{result: %{}, matched_rules: [], hit_policy: :first}} end
      }
    }

    {:ok, worker_pid} = RegressionTesterWorker.start_link(facade: facade, test_inputs: [])

    Process.sleep(150)

    report = RegressionTesterWorker.get_last_report(worker_pid)

    assert report.total_inputs == 0
    assert report.regression_detected == false

    GenServer.stop(worker_pid, :normal, 5_000)
  end
end
