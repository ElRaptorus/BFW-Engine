defmodule Examples.BusinessRules.DecisionServiceSmokeTester.SmokeTesterWorkerTest do
  use ExUnit.Case

  alias EvilEngine.DMN.{EvaluationTrace, ServiceEvaluationResult}
  alias EvilEngine.EngineFacade
  alias Examples.BusinessRules.DecisionServiceSmokeTester.SmokeTesterWorker

  @insurance_dmn_xml """
  <?xml version="1.0" encoding="UTF-8"?>
  <definitions>
    <decisionService id="PricingService" name="Pricing Service"/>
  </definitions>
  """

  @other_dmn_xml """
  <?xml version="1.0" encoding="UTF-8"?>
  <definitions>
    <decisionService id="BrokenService" name="Broken Service"/>
  </definitions>
  """

  test "worker enumerates models, discovers services, evaluates each, and produces a healthy report" do
    {:ok, calls_agent} = Agent.start_link(fn -> [] end)

    append_event = fn event ->
      Agent.update(calls_agent, fn events -> events ++ [event] end)
    end

    facade = %EngineFacade{
      engine_id: "test-engine-id",
      engine_name: "test-engine-name",
      version: "0.0.0-test",
      decisions: %EngineFacade.Decisions{
        list: fn ->
          append_event.(:list)

          {:ok,
           [
             %{decision_definition_id: "insurance-pricing"},
             %{decision_definition_id: "other-model"}
           ]}
        end,
        get_xml: fn model_id ->
          append_event.({:get_xml, model_id})

          case model_id do
            "insurance-pricing" -> {:ok, @insurance_dmn_xml}
            "other-model" -> {:ok, @other_dmn_xml}
            _other -> {:error, :not_found}
          end
        end,
        evaluate_service: fn model_id, service_id, test_input, _options ->
          append_event.({:evaluate_service, model_id, service_id, test_input})

          if service_id == "BrokenService" do
            {:error, {:service_not_found, service_id}}
          else
            {:ok,
             %ServiceEvaluationResult{
               service_id: service_id,
               service_name: "Test Service",
               outputs: %{"Final Premium" => 450},
               trace: %EvaluationTrace{decisions: []},
               evaluated_at: DateTime.utc_now(),
               duration_microseconds: 9_500
             }}
          end
        end
      }
    }

    {:ok, worker_pid} = SmokeTesterWorker.start_link(facade: facade)

    Process.sleep(150)

    events = Agent.get(calls_agent, & &1)
    report = SmokeTesterWorker.get_last_report(worker_pid)

    assert :list in events
    assert {:get_xml, "insurance-pricing"} in events
    assert {:get_xml, "other-model"} in events
    assert Enum.count(events, &match?({:evaluate_service, _, _, _}, &1)) == 2

    assert report.total_models == 2
    assert report.total_services == 2
    assert report.healthy == 1
    assert report.unhealthy == 1

    pricing_detail =
      Enum.find(report.details, &(&1.service_id == "PricingService"))

    assert pricing_detail.status == :healthy
    assert pricing_detail.duration_us == 9_500

    broken_detail =
      Enum.find(report.details, &(&1.service_id == "BrokenService"))

    assert broken_detail.status == :unhealthy
    assert broken_detail.error == {:service_not_found, "BrokenService"}

    GenServer.stop(worker_pid, :normal, 5_000)
  end

  test "worker records healthy status with evaluation result for successful service" do
    facade = %EngineFacade{
      engine_id: "test-engine-id",
      engine_name: "test-engine-name",
      version: "0.0.0-test",
      decisions: %EngineFacade.Decisions{
        list: fn ->
          {:ok, [%{decision_definition_id: "insurance-pricing"}]}
        end,
        get_xml: fn "insurance-pricing" -> {:ok, @insurance_dmn_xml} end,
        evaluate_service: fn "insurance-pricing", "PricingService", test_input, _options ->
          assert test_input["age"] == 35
          assert test_input["coverage"] == "standard"

          {:ok,
           %ServiceEvaluationResult{
             service_id: "PricingService",
             service_name: "Pricing Service",
             outputs: %{"Final Premium" => 450},
             trace: %EvaluationTrace{decisions: []},
             evaluated_at: DateTime.utc_now(),
             duration_microseconds: 12_400
           }}
        end
      }
    }

    {:ok, worker_pid} = SmokeTesterWorker.start_link(facade: facade)

    Process.sleep(150)

    report = SmokeTesterWorker.get_last_report(worker_pid)

    assert report.healthy == 1
    assert report.unhealthy == 0

    detail = hd(report.details)
    assert detail.status == :healthy
    assert detail.result_shape.output_keys == ["Final Premium"]

    GenServer.stop(worker_pid, :normal, 5_000)
  end

  test "worker with no deployed models produces empty report without crashing" do
    facade = %EngineFacade{
      engine_id: "test-engine-id",
      engine_name: "test-engine-name",
      version: "0.0.0-test",
      decisions: %EngineFacade.Decisions{
        list: fn -> {:ok, []} end
      }
    }

    {:ok, worker_pid} = SmokeTesterWorker.start_link(facade: facade)

    Process.sleep(150)

    report = SmokeTesterWorker.get_last_report(worker_pid)

    assert report.total_models == 0
    assert report.total_services == 0
    assert report.healthy == 0
    assert report.unhealthy == 0
    assert report.details == []

    GenServer.stop(worker_pid, :normal, 5_000)
  end
end
