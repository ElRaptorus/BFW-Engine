defmodule Examples.BusinessRules.DrdChainOrchestrator.TraceInspectorTest do
  use ExUnit.Case

  alias Examples.BusinessRules.DrdChainOrchestrator.TraceInspector

  @four_decision_trace %{
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
              %{"name" => "creditHistory", "bound_value" => "good"},
              %{"name" => "annualIncome", "bound_value" => 75_000},
              %{"name" => "existingDebt", "bound_value" => 15_000}
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
        "result" => %{"riskLevel" => "moderate_low", "maxApprovalPercent" => 0.85},
        "duration_microseconds" => 450,
        "inputs" => [%{}, %{}]
      },
      %{
        "decision_name" => "Underwriting Decision",
        "hit_policy" => "unique",
        "result" => %{
          "approved" => true,
          "approvedAmount" => 300_000,
          "conditions" => "income_verification"
        },
        "duration_microseconds" => 900,
        "inputs" => [%{}, %{}]
      }
    ]
  }

  test "format_chain formats four-decision chain with step numbers and results" do
    chain = TraceInspector.format_chain(@four_decision_trace)

    assert length(chain) == 4
    assert Enum.map(chain, & &1.step) == [1, 2, 3, 4]
    assert Enum.at(chain, 0).decision == "Applicant Credit Score"
    assert Enum.at(chain, 0).result == 720
    assert Enum.at(chain, 3).decision == "Underwriting Decision"
    assert Enum.at(chain, 3).result["approved"] == true
  end

  test "format_chain shows BKM invocations with parameter bindings" do
    chain = TraceInspector.format_chain(@four_decision_trace)
    [first_step | _rest] = chain

    assert length(first_step.bkm_invocations) == 1

    [bkm_invocation | _] = first_step.bkm_invocations
    assert bkm_invocation.bkm_name == "Credit Score Calculator"
    assert bkm_invocation.result == 720

    assert {"creditHistory", "good"} in bkm_invocation.parameters
    assert {"annualIncome", 75_000} in bkm_invocation.parameters
    assert {"existingDebt", 15_000} in bkm_invocation.parameters
  end

  test "format_chain handles nested BKM chains recursively" do
    trace = %{
      "decisions" => [
        %{
          "decision_name" => "Nested BKM Decision",
          "hit_policy" => "unique",
          "result" => 100,
          "duration_microseconds" => 50,
          "bkm_traces" => [
            %{
              "bkm_name" => "Outer BKM",
              "formal_parameters" => [%{"name" => "value", "bound_value" => 1}],
              "result" => 100,
              "dependent_bkm_traces" => [
                %{
                  "bkm_name" => "Inner BKM",
                  "formal_parameters" => [%{"name" => "factor", "bound_value" => 2}],
                  "result" => 50,
                  "dependent_bkm_traces" => []
                }
              ]
            }
          ],
          "inputs" => []
        }
      ]
    }

    chain = TraceInspector.format_chain(trace)
    [step] = chain
    [outer_bkm] = step.bkm_invocations
    [inner_bkm] = outer_bkm.nested_bkms

    assert outer_bkm.bkm_name == "Outer BKM"
    assert inner_bkm.bkm_name == "Inner BKM"
    assert inner_bkm.nested_bkms == []
  end

  test "format_chain returns empty list for empty trace" do
    assert TraceInspector.format_chain(%{}) == []
    assert TraceInspector.format_chain(%{"decisions" => []}) == []
  end

  test "format_chain treats missing bkm_traces key as empty invocations" do
    trace = %{
      "decisions" => [
        %{
          "decision_name" => "Literal Decision",
          "hit_policy" => "unique",
          "result" => 42,
          "duration_microseconds" => 10,
          "inputs" => []
        }
      ]
    }

    chain = TraceInspector.format_chain(trace)
    assert hd(chain).bkm_invocations == []
  end

  test "format_chain accepts traces with atom keys" do
    trace = %{
      decisions: [
        %{
          decision_name: "Atom Key Decision",
          hit_policy: "first",
          result: "ok",
          duration_microseconds: 5,
          inputs: []
        }
      ]
    }

    chain = TraceInspector.format_chain(trace)
    assert hd(chain).decision == "Atom Key Decision"
  end

  test "format_summary produces readable text for a formatted chain" do
    chain = TraceInspector.format_chain(@four_decision_trace)
    summary = TraceInspector.format_summary(chain)

    assert summary =~ "DRD evaluation chain (4 decisions)"
    assert summary =~ "Step 1: Applicant Credit Score"
    assert summary =~ "Step 4: Underwriting Decision"
    assert summary =~ "bkm_invocations=1"
  end
end
