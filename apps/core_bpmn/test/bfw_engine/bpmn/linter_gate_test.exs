defmodule BfwEngine.BPMN.LinterGateTest do
  use ExUnit.Case, async: false

  alias BfwEngine.BPMN.LinterGate
  alias BfwEngine.BPMN.Model.Definitions
  alias BfwEngine.BPMN.Model.LinterRulesetScore

  # The linter gate reads scores from the **definitions** level (ESP-D17), not
  # from individual processes. These helpers build a `%Definitions{}` carrying
  # the Studio-emitted score entries directly.
  defp definitions_with_scores(linter_scores) do
    %Definitions{raw_xml: "", processes: [], linter_scores: linter_scores}
  end

  describe "check/2" do
    test "passes when scores meet all thresholds for one ruleset" do
      definitions =
        definitions_with_scores([
          %LinterRulesetScore{
            ruleset_id: "bfw-default",
            score_percent: 95,
            raw_error_findings: 0,
            raw_warning_findings: 1,
            compliance_status: "pass",
            schema_version: "1"
          }
        ])

      config = %{
        "bfw-default" => %{
          "requirePresence" => true,
          "minScorePercent" => 90,
          "maxErrors" => 0,
          "maxWarnings" => 2,
          "requireComplianceStatus" => "pass",
          "schemaVersion" => "1"
        }
      }

      assert {:ok, :passed} = LinterGate.check(definitions, config)
    end

    test "passes when multiple configured rulesets all pass" do
      definitions =
        definitions_with_scores([
          %LinterRulesetScore{ruleset_id: "a", score_percent: 100},
          %LinterRulesetScore{ruleset_id: "b", score_percent: 80}
        ])

      config = %{
        "a" => %{"minScorePercent" => 90},
        "b" => %{"minScorePercent" => 70}
      }

      assert {:ok, :passed} = LinterGate.check(definitions, config)
    end

    test "ignores BPMN rulesets that have no gate config" do
      definitions =
        definitions_with_scores([
          %LinterRulesetScore{ruleset_id: "only-in-bpmn", score_percent: 10},
          %LinterRulesetScore{ruleset_id: "gated", score_percent: 100}
        ])

      config = %{"gated" => %{"minScorePercent" => 50}}

      assert {:ok, :passed} = LinterGate.check(definitions, config)
    end

    test "empty explicit config is a no-op" do
      definitions =
        definitions_with_scores([
          %LinterRulesetScore{ruleset_id: "x", score_percent: 0}
        ])

      assert {:ok, :passed} = LinterGate.check(definitions, %{})
    end

    test "fails requirePresence when ruleset is absent" do
      definitions = definitions_with_scores([])

      config = %{"bfw-default" => %{"requirePresence" => true}}

      assert {:error, failures} = LinterGate.check(definitions, config)

      assert %{
               ruleset_id: "bfw-default",
               check: "requirePresence",
               expected: true,
               actual: false
             } in failures
    end

    test "fails minScorePercent below threshold" do
      definitions =
        definitions_with_scores([
          %LinterRulesetScore{ruleset_id: "bfw-default", score_percent: 70}
        ])

      config = %{"bfw-default" => %{"minScorePercent" => 90}}

      assert {:error, [%{check: "minScorePercent", expected: 90, actual: 70} = failure]} =
               LinterGate.check(definitions, config)

      assert failure.ruleset_id == "bfw-default"
    end

    test "fails maxErrors when rawErrorFindings exceeds limit" do
      definitions =
        definitions_with_scores([
          %LinterRulesetScore{
            ruleset_id: "bfw-default",
            score_percent: 100,
            raw_error_findings: 5
          }
        ])

      config = %{"bfw-default" => %{"maxErrors" => 2}}

      assert {:error, [%{check: "maxErrors", expected: 2, actual: 5}]} =
               LinterGate.check(definitions, config)
    end

    test "fails maxWarnings when rawWarningFindings exceeds limit" do
      definitions =
        definitions_with_scores([
          %LinterRulesetScore{
            ruleset_id: "bfw-default",
            score_percent: 100,
            raw_warning_findings: 4
          }
        ])

      config = %{"bfw-default" => %{"maxWarnings" => 1}}

      assert {:error, [%{check: "maxWarnings", expected: 1, actual: 4}]} =
               LinterGate.check(definitions, config)
    end

    test "fails requireComplianceStatus on mismatch" do
      definitions =
        definitions_with_scores([
          %LinterRulesetScore{
            ruleset_id: "bfw-default",
            score_percent: 100,
            compliance_status: "fail"
          }
        ])

      config = %{"bfw-default" => %{"requireComplianceStatus" => "pass"}}

      assert {:error,
              [
                %{
                  check: "requireComplianceStatus",
                  expected: "pass",
                  actual: "fail"
                }
              ]} = LinterGate.check(definitions, config)
    end

    test "fails schemaVersion on mismatch" do
      definitions =
        definitions_with_scores([
          %LinterRulesetScore{
            ruleset_id: "bfw-default",
            score_percent: 100,
            schema_version: "2"
          }
        ])

      config = %{"bfw-default" => %{"schemaVersion" => "1"}}

      assert {:error,
              [
                %{
                  check: "schemaVersion",
                  expected: "1",
                  actual: "2"
                }
              ]} = LinterGate.check(definitions, config)
    end

    test "collects failures across rulesets in one response" do
      definitions =
        definitions_with_scores([
          %LinterRulesetScore{ruleset_id: "a", score_percent: 50},
          %LinterRulesetScore{ruleset_id: "b", score_percent: 50}
        ])

      config = %{
        "a" => %{"minScorePercent" => 90},
        "b" => %{"minScorePercent" => 90}
      }

      assert {:error, failures} = LinterGate.check(definitions, config)
      assert length(failures) == 2

      rulesets = failures |> Enum.map(& &1.ruleset_id) |> Enum.sort()
      assert rulesets == ["a", "b"]
    end

    test "multiple checks can fail for the same ruleset" do
      definitions =
        definitions_with_scores([
          %LinterRulesetScore{
            ruleset_id: "bfw-default",
            score_percent: 50,
            raw_error_findings: 9,
            raw_warning_findings: 9
          }
        ])

      config = %{
        "bfw-default" => %{
          "minScorePercent" => 90,
          "maxErrors" => 0,
          "maxWarnings" => 0
        }
      }

      assert {:error, failures} = LinterGate.check(definitions, config)
      checks = failures |> Enum.map(& &1.check) |> Enum.sort()
      assert checks == ["maxErrors", "maxWarnings", "minScorePercent"]
    end

    test "definitions with no linter scores fail when gate requires presence" do
      definitions = definitions_with_scores([])

      config = %{"bfw-default" => %{"requirePresence" => true}}

      assert {:error, [%{check: "requirePresence"}]} = LinterGate.check(definitions, config)
    end
  end

  describe "check/1 (application env)" do
    setup do
      previous = Application.get_env(:core_bpmn, :linter_gate)

      on_exit(fn ->
        if previous == nil do
          Application.delete_env(:core_bpmn, :linter_gate)
        else
          Application.put_env(:core_bpmn, :linter_gate, previous)
        end
      end)

      :ok
    end

    test "no linter_gate config is a no-op" do
      Application.delete_env(:core_bpmn, :linter_gate)

      definitions = definitions_with_scores([])

      assert {:ok, :passed} = LinterGate.check(definitions)
    end
  end
end
