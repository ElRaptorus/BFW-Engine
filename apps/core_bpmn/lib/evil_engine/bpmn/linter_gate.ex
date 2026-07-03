defmodule EvilEngine.BPMN.LinterGate do
  @moduledoc """
  Deploy-time quality gate based on linter ruleset scores.

  Reads gate configuration from `:core_bpmn, :linter_gate` and checks the
  **definitions-level** `LinterRulesetScore` entries (written by the Studio
  under `definitions/extensionElements/evil:Properties`, ESP-D17) against the
  configured thresholds. Six check types are supported, each mapped to a field
  on the Studio-emitted score entry:

  - `requirePresence` — the ruleset must be present in the BPMN
  - `minScorePercent` — minimum `scorePercent`
  - `maxErrors` — maximum `rawErrorFindings`
  - `maxWarnings` — maximum `rawWarningFindings`
  - `requireComplianceStatus` — exact match on `complianceStatus`
  - `schemaVersion` — exact match on `schemaVersion`

  Returns `{:ok, :passed}` when all checks pass, or `{:error, failures}` with
  a list of violation maps.
  """

  alias EvilEngine.BPMN.Model.Definitions

  @type failure :: %{
          ruleset_id: String.t(),
          check: String.t(),
          expected: term(),
          actual: term()
        }

  @doc """
  Run the linter gate against a parsed `%Definitions{}`.

  Uses the gate configuration from application env. If no gate is
  configured (nil, empty, or unparseable), the gate is a no-op and
  returns `{:ok, :passed}`.
  """
  @spec check(Definitions.t()) :: {:ok, :passed} | {:error, [failure()]}
  def check(%Definitions{} = definitions) do
    case gate_config() do
      config when config == %{} -> {:ok, :passed}
      config -> run(definitions, config)
    end
  end

  @doc """
  Run the linter gate with an explicit config map (useful for testing
  without relying on application env).
  """
  @spec check(Definitions.t(), map()) :: {:ok, :passed} | {:error, [failure()]}
  def check(%Definitions{} = definitions, config) when is_map(config) do
    if config == %{}, do: {:ok, :passed}, else: run(definitions, config)
  end

  defp run(definitions, config) do
    failures =
      Enum.flat_map(config, fn {ruleset_id, ruleset_config} ->
        score_entry =
          Enum.find(definitions.linter_scores, &(&1.ruleset_id == ruleset_id))

        check_ruleset(ruleset_id, ruleset_config, score_entry)
      end)

    if failures == [], do: {:ok, :passed}, else: {:error, failures}
  end

  defp check_ruleset(ruleset_id, config, score_entry) do
    [
      check_require_presence(ruleset_id, config, score_entry),
      check_min_score(ruleset_id, config, score_entry),
      check_max_errors(ruleset_id, config, score_entry),
      check_max_warnings(ruleset_id, config, score_entry),
      check_compliance_status(ruleset_id, config, score_entry),
      check_schema_version(ruleset_id, config, score_entry)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp check_require_presence(ruleset_id, %{"requirePresence" => true}, nil) do
    %{ruleset_id: ruleset_id, check: "requirePresence", expected: true, actual: false}
  end

  defp check_require_presence(_ruleset_id, _config, _score), do: nil

  defp check_min_score(ruleset_id, %{"minScorePercent" => min}, %{score_percent: score})
       when is_number(score) and score < min do
    %{ruleset_id: ruleset_id, check: "minScorePercent", expected: min, actual: score}
  end

  defp check_min_score(_ruleset_id, _config, _score), do: nil

  defp check_max_errors(ruleset_id, %{"maxErrors" => max}, %{raw_error_findings: actual})
       when is_number(actual) and actual > max do
    %{ruleset_id: ruleset_id, check: "maxErrors", expected: max, actual: actual}
  end

  defp check_max_errors(_ruleset_id, _config, _score), do: nil

  defp check_max_warnings(ruleset_id, %{"maxWarnings" => max}, %{raw_warning_findings: actual})
       when is_number(actual) and actual > max do
    %{ruleset_id: ruleset_id, check: "maxWarnings", expected: max, actual: actual}
  end

  defp check_max_warnings(_ruleset_id, _config, _score), do: nil

  defp check_compliance_status(
         ruleset_id,
         %{"requireComplianceStatus" => expected},
         %{compliance_status: actual}
       )
       when actual != expected do
    %{
      ruleset_id: ruleset_id,
      check: "requireComplianceStatus",
      expected: expected,
      actual: actual
    }
  end

  defp check_compliance_status(_ruleset_id, _config, _score), do: nil

  defp check_schema_version(ruleset_id, %{"schemaVersion" => expected}, %{schema_version: actual})
       when actual != expected do
    %{ruleset_id: ruleset_id, check: "schemaVersion", expected: expected, actual: actual}
  end

  defp check_schema_version(_ruleset_id, _config, _score), do: nil

  defp gate_config do
    case Application.get_env(:core_bpmn, :linter_gate) do
      nil -> %{}
      config when is_list(config) -> parse_rules(Keyword.get(config, :rules))
      _ -> %{}
    end
  end

  defp parse_rules(nil), do: %{}
  defp parse_rules(""), do: %{}

  defp parse_rules(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, config} when is_map(config) -> config
      _ -> %{}
    end
  end

  defp parse_rules(config) when is_map(config), do: config
  defp parse_rules(_), do: %{}
end
