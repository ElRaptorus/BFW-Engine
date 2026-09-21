defmodule Examples.BusinessRules.DecisionAuditReporter.BoundaryTesterTest do
  use ExUnit.Case, async: true

  alias BfwEngine.EngineFacade
  alias Examples.BusinessRules.DecisionAuditReporter.BoundaryTester

  test "evaluates decision with inputs via facade and records success results" do
    {:ok, calls_agent} = Agent.start_link(fn -> [] end)

    facade = %EngineFacade{
      engine_id: "test-engine-id",
      engine_name: "test-engine-name",
      version: "0.0.0-test",
      decisions: %EngineFacade.Decisions{
        evaluate: fn decision_ref, input, _options ->
          Agent.update(calls_agent, fn calls -> [{decision_ref, input} | calls] end)
          {:ok, %{result: %{"tier" => "gold"}, matched_rules: [%{rule_id: "rule_2"}]}}
        end
      }
    }

    input = %{
      "yearsOfService" => 12,
      "department" => "sales",
      "performanceRating" => "outstanding",
      "employeeType" => "full_time"
    }

    results =
      BoundaryTester.test_all(facade, [
        %{
          decision_ref: "employee-benefits",
          boundary_inputs: [%{test_case: "gold_outstanding", input: input}]
        }
      ])

    model_results = results["employee-benefits"]
    assert length(model_results) == 1

    assert hd(model_results) == %{
             test_case: "gold_outstanding",
             input: input,
             result: %{"tier" => "gold"},
             error: nil
           }

    assert Agent.get(calls_agent, & &1) == [{"employee-benefits", input}]
  end

  test "records error results when evaluation fails" do
    facade = %EngineFacade{
      engine_id: "test-engine-id",
      engine_name: "test-engine-name",
      version: "0.0.0-test",
      decisions: %EngineFacade.Decisions{
        evaluate: fn _decision_ref, _input, _options ->
          {:error, :dmn_evaluation_error}
        end
      }
    }

    results =
      BoundaryTester.test_all(facade, [
        %{
          decision_ref: "employee-benefits",
          boundary_inputs: [
            %{test_case: "invalid_input", input: %{"yearsOfService" => -1}}
          ]
        }
      ])

    model_result = hd(results["employee-benefits"])
    assert model_result.result == nil
    assert model_result.error == ":dmn_evaluation_error"
  end
end
