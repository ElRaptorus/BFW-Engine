defmodule EvilEngine.Integration.Deployment.LinterGateIntegrationTest do
  use ExUnit.Case, async: true

  alias EvilEngine.BPMN.LinterGate
  alias EvilEngine.BPMN.Model.Definitions
  alias EvilEngine.BPMN.Model.LinterRulesetScore
  alias EvilEngine.BPMN.Model.Process

  defp sample_definitions(opts \\ []) do
    score = Keyword.get(opts, :score, 95)
    ruleset_id = Keyword.get(opts, :ruleset_id, "evil-default")

    %Definitions{
      raw_xml: "<bpmn/>",
      processes: [
        %Process{
          id: "deployed-process",
          version: "1.0.0",
          linter_scores: [
            %LinterRulesetScore{
              ruleset_id: ruleset_id,
              score: score,
              checks: %{"errors" => 0, "warnings" => 2}
            }
          ]
        }
      ]
    }
  end

  test "check/2 returns {:ok, :passed} when config thresholds pass" do
    definitions = sample_definitions()

    passing_config = %{
      "evil-default" => %{
        "minScorePercent" => 90,
        "maxErrors" => 1
      }
    }

    assert {:ok, :passed} = LinterGate.check(definitions, passing_config)
  end

  test "check/2 returns {:error, failures} when config fails" do
    definitions = sample_definitions(score: 70)

    strict_config = %{
      "evil-default" => %{
        "minScorePercent" => 85
      }
    }

    assert {:error, failures} = LinterGate.check(definitions, strict_config)
    assert is_list(failures)
    assert Enum.any?(failures, &(&1.check == "minScorePercent"))
  end
end
