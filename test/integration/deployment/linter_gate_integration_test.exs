defmodule BfwEngine.Integration.Deployment.LinterGateIntegrationTest do
  use ExUnit.Case, async: false

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

  alias BfwEngine.BPMN.LinterGate
  alias BfwEngine.BPMN.Model.Definitions
  alias BfwEngine.BPMN.Model.LinterRulesetScore

  # Linter scores are scoped to the definitions (ESP-D17), matching the
  # Studio-emitted `definitions/extensionElements/bfw:properties` shape.
  defp sample_definitions(opts \\ []) do
    score = Keyword.get(opts, :score, 95)
    ruleset_id = Keyword.get(opts, :ruleset_id, "bfw-default")

    %Definitions{
      raw_xml: "<bpmn/>",
      processes: [],
      linter_scores: [
        %LinterRulesetScore{
          ruleset_id: ruleset_id,
          score_percent: score,
          raw_error_findings: 0,
          raw_warning_findings: 2
        }
      ]
    }
  end

  test "check/1 returns {:ok, :passed} when config thresholds pass" do
    definitions = sample_definitions()

    Application.put_env(:core_bpmn, :linter_gate,
      rules: %{
        "bfw-default" => %{
          "minScorePercent" => 90,
          "maxErrors" => 1
        }
      }
    )

    assert {:ok, :passed} = LinterGate.check(definitions)
  end

  test "check/1 returns {:error, failures} when config fails" do
    definitions = sample_definitions(score: 70)

    Application.put_env(:core_bpmn, :linter_gate,
      rules: %{
        "bfw-default" => %{
          "minScorePercent" => 85
        }
      }
    )

    assert {:error, failures} = LinterGate.check(definitions)
    assert is_list(failures)
    assert Enum.any?(failures, &(&1.check == "minScorePercent"))
  end
end
