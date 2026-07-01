defmodule Examples.BusinessRules.ExplainDecision.ScriptTest do
  use ExUnit.Case

  alias Examples.BusinessRules.ExplainDecision.Script

  describe "handle_enter/3" do
    test "single-decision trace produces a readable explanation with inputs and result" do
      payload = %{
        "trace" => %{
          "decisions" => [
            %{
              "decision_name" => "Loan Eligibility",
              "inputs" => [
                %{
                  "input_id" => "creditScore",
                  "input_label" => "Credit Score",
                  "resolved_value" => 720
                },
                %{
                  "input_id" => "annualIncome",
                  "input_label" => "Annual Income",
                  "resolved_value" => 55_000
                }
              ],
              "matched_rules" => [%{"rule_id" => "rule_excellent", "rule_index" => 3}],
              "result" => %{
                "approved" => true,
                "maxAmount" => 500_000,
                "reason" => "Excellent profile"
              }
            }
          ]
        }
      }

      assert {:ok, result} = Script.handle_enter(%{}, payload, %{})

      assert result["decision_count"] == 1
      assert is_binary(result["explanation"])
      assert result["explanation"] =~ "Decision 'Loan Eligibility':"
      assert result["explanation"] =~ "Credit Score = 720"
      assert result["explanation"] =~ "Annual Income = 55000"
      assert result["explanation"] =~ "1 rule(s) matched"
      assert result["explanation"] =~ "Excellent profile"
    end

    test "multi-decision trace produces one explanation per decision joined by double newline" do
      payload = %{
        "trace" => %{
          "decisions" => [
            %{
              "decision_name" => "Risk Score",
              "inputs" => [
                %{"input_id" => "orderTotal", "input_label" => "Order Total", "resolved_value" => 1200}
              ],
              "matched_rules" => [%{"rule_id" => "rule_1", "rule_index" => 0}],
              "result" => %{"riskPoints" => 20}
            },
            %{
              "decision_name" => "Risk Level",
              "inputs" => [
                %{"input_id" => "riskScore", "input_label" => "Risk Score", "resolved_value" => 20}
              ],
              "matched_rules" => [%{"rule_id" => "rule_low", "rule_index" => 0}],
              "result" => %{"level" => "low", "action" => "auto_approve"}
            }
          ]
        }
      }

      assert {:ok, result} = Script.handle_enter(%{}, payload, %{})

      assert result["decision_count"] == 2
      parts = String.split(result["explanation"], "\n\n")
      assert length(parts) == 2
      assert hd(parts) =~ "Decision 'Risk Score':"
      assert List.last(parts) =~ "Decision 'Risk Level':"
    end

    test "empty trace yields an empty explanation and decision_count zero" do
      payload = %{"trace" => %{"decisions" => []}}

      assert {:ok, %{"explanation" => "", "decision_count" => 0}} =
               Script.handle_enter(%{}, payload, %{})
    end

    test "missing trace fields use fallback labels without crashing" do
      payload = %{
        "trace" => %{
          "decisions" => [
            %{
              "matched_rules" => [],
              "result" => %{"approved" => false}
            }
          ]
        }
      }

      assert {:ok, result} = Script.handle_enter(%{}, payload, %{})

      assert result["decision_count"] == 1
      assert result["explanation"] =~ "Decision 'Unknown':"
      assert result["explanation"] =~ "0 rule(s) matched"
    end

    test "missing trace key yields empty explanation" do
      assert {:ok, %{"explanation" => "", "decision_count" => 0}} =
               Script.handle_enter(%{}, %{}, %{})
    end

    test "non-map payload yields empty explanation" do
      assert {:ok, %{"explanation" => "", "decision_count" => 0}} =
               Script.handle_enter(%{}, "not a map", %{})
    end

    test "output map contains explanation string and decision_count integer" do
      payload = %{
        "trace" => %{
          "decisions" => [
            %{
              "decision_name" => "Loan Eligibility",
              "inputs" => [],
              "matched_rules" => [],
              "result" => %{"approved" => true}
            }
          ]
        }
      }

      assert {:ok, result} = Script.handle_enter(%{}, payload, %{})

      assert is_binary(result["explanation"])
      assert is_integer(result["decision_count"])
    end
  end
end
