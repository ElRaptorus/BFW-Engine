defmodule EvilEngine.BPMN.LinterGateTest do
  use ExUnit.Case, async: false

  alias EvilEngine.BPMN.LinterGate
  alias EvilEngine.BPMN.Model.Definitions
  alias EvilEngine.BPMN.Model.LinterRulesetScore
  alias EvilEngine.BPMN.Model.Process, as: BpmnProcess

  defp definitions_with_processes(processes) do
    %Definitions{raw_xml: "", processes: processes}
  end

  defp process_with_scores(linter_scores) do
    %BpmnProcess{
      id: "P1",
      version: "1.0.0",
      linter_scores: linter_scores
    }
  end

  describe "check/2" do
    test "passes when scores meet all thresholds for one ruleset" do
      definitions =
        definitions_with_processes([
          process_with_scores([
            %LinterRulesetScore{
              ruleset_id: "evil-default",
              score: 95,
              checks: %{
                "errors" => 0,
                "warnings" => 1,
                "complianceStatus" => "pass",
                "schemaVersion" => "1"
              }
            }
          ])
        ])

      config = %{
        "evil-default" => %{
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
      scores = [
        %LinterRulesetScore{ruleset_id: "a", score: 100, checks: %{}},
        %LinterRulesetScore{ruleset_id: "b", score: 80, checks: %{}}
      ]

      definitions = definitions_with_processes([process_with_scores(scores)])

      config = %{
        "a" => %{"minScorePercent" => 90},
        "b" => %{"minScorePercent" => 70}
      }

      assert {:ok, :passed} = LinterGate.check(definitions, config)
    end

    test "ignores BPMN rulesets that have no gate config" do
      definitions =
        definitions_with_processes([
          process_with_scores([
            %LinterRulesetScore{ruleset_id: "only-in-bpmn", score: 10, checks: %{}},
            %LinterRulesetScore{ruleset_id: "gated", score: 100, checks: %{}}
          ])
        ])

      config = %{"gated" => %{"minScorePercent" => 50}}

      assert {:ok, :passed} = LinterGate.check(definitions, config)
    end

    test "empty explicit config is a no-op" do
      definitions =
        definitions_with_processes([
          process_with_scores([
            %LinterRulesetScore{ruleset_id: "x", score: 0, checks: %{}}
          ])
        ])

      assert {:ok, :passed} = LinterGate.check(definitions, %{})
    end

    test "fails requirePresence when ruleset is absent" do
      definitions = definitions_with_processes([process_with_scores([])])

      config = %{"evil-default" => %{"requirePresence" => true}}

      assert {:error, failures} = LinterGate.check(definitions, config)

      assert %{
               ruleset_id: "evil-default",
               check: "requirePresence",
               expected: true,
               actual: false
             } in failures
    end

    test "fails minScorePercent below threshold" do
      definitions =
        definitions_with_processes([
          process_with_scores([
            %LinterRulesetScore{ruleset_id: "evil-default", score: 70, checks: %{}}
          ])
        ])

      config = %{"evil-default" => %{"minScorePercent" => 90}}

      assert {:error, [%{check: "minScorePercent", expected: 90, actual: 70} = failure]} =
               LinterGate.check(definitions, config)

      assert failure.ruleset_id == "evil-default"
    end

    test "fails maxErrors when error count exceeds limit" do
      definitions =
        definitions_with_processes([
          process_with_scores([
            %LinterRulesetScore{
              ruleset_id: "evil-default",
              score: 100,
              checks: %{"errors" => 5}
            }
          ])
        ])

      config = %{"evil-default" => %{"maxErrors" => 2}}

      assert {:error, [%{check: "maxErrors", expected: 2, actual: 5}]} =
               LinterGate.check(definitions, config)
    end

    test "fails maxWarnings when warning count exceeds limit" do
      definitions =
        definitions_with_processes([
          process_with_scores([
            %LinterRulesetScore{
              ruleset_id: "evil-default",
              score: 100,
              checks: %{"warnings" => 4}
            }
          ])
        ])

      config = %{"evil-default" => %{"maxWarnings" => 1}}

      assert {:error, [%{check: "maxWarnings", expected: 1, actual: 4}]} =
               LinterGate.check(definitions, config)
    end

    test "fails requireComplianceStatus on mismatch" do
      definitions =
        definitions_with_processes([
          process_with_scores([
            %LinterRulesetScore{
              ruleset_id: "evil-default",
              score: 100,
              checks: %{"complianceStatus" => "fail"}
            }
          ])
        ])

      config = %{"evil-default" => %{"requireComplianceStatus" => "pass"}}

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
        definitions_with_processes([
          process_with_scores([
            %LinterRulesetScore{
              ruleset_id: "evil-default",
              score: 100,
              checks: %{"schemaVersion" => "2"}
            }
          ])
        ])

      config = %{"evil-default" => %{"schemaVersion" => "1"}}

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
        definitions_with_processes([
          process_with_scores([
            %LinterRulesetScore{ruleset_id: "a", score: 50, checks: %{}},
            %LinterRulesetScore{ruleset_id: "b", score: 50, checks: %{}}
          ])
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
        definitions_with_processes([
          process_with_scores([
            %LinterRulesetScore{
              ruleset_id: "evil-default",
              score: 50,
              checks: %{"errors" => 9, "warnings" => 9}
            }
          ])
        ])

      config = %{
        "evil-default" => %{
          "minScorePercent" => 90,
          "maxErrors" => 0,
          "maxWarnings" => 0
        }
      }

      assert {:error, failures} = LinterGate.check(definitions, config)
      checks = failures |> Enum.map(& &1.check) |> Enum.sort()
      assert checks == ["maxErrors", "maxWarnings", "minScorePercent"]
    end

    test "process with no linter scores fails when gate requires presence" do
      definitions =
        definitions_with_processes([%BpmnProcess{id: "P1", version: "1.0.0", linter_scores: []}])

      config = %{"evil-default" => %{"requirePresence" => true}}

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

      definitions =
        definitions_with_processes([
          process_with_scores([])
        ])

      assert {:ok, :passed} = LinterGate.check(definitions)
    end
  end
end
