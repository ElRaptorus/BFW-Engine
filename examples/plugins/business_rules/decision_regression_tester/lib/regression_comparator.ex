defmodule Examples.BusinessRules.DecisionRegressionTester.RegressionComparator do
  @moduledoc """
  Pure comparison helpers for two DMN evaluation results against the same input.
  """

  @type comparison :: map()
  @type evaluation_snapshot :: %{
          optional(:result) => term(),
          optional(:matched_rules) => [String.t()],
          optional(:hit_policy) => atom() | String.t()
        }

  @doc """
  Compares two evaluation snapshots for one input.

  `result_v1` and `result_v2` are maps (or structs coerced to maps) with keys
  `:result`, `:matched_rules`, and `:hit_policy`.
  """
  @spec compare(evaluation_snapshot(), evaluation_snapshot(), map()) :: comparison()
  def compare(result_v1, result_v2, input) do
    cond do
      result_v1.result == result_v2.result ->
        %{input: input, status: :identical, v1: result_v1.result, v2: result_v2.result}

      true ->
        %{
          input: input,
          status: :diverged,
          v1: result_v1.result,
          v2: result_v2.result,
          v1_matched_rules: result_v1.matched_rules,
          v2_matched_rules: result_v2.matched_rules,
          v1_hit_policy: result_v1.hit_policy,
          v2_hit_policy: result_v2.hit_policy
        }
    end
  end

  @doc "Builds a summary report from a list of per-input comparisons."
  @spec build_report([comparison()]) :: map()
  def build_report(comparisons) do
    identical = Enum.count(comparisons, &(&1.status == :identical))
    diverged = Enum.count(comparisons, &(&1.status == :diverged))

    %{
      total_inputs: length(comparisons),
      identical: identical,
      diverged: diverged,
      regression_detected: diverged > 0,
      details: Enum.filter(comparisons, &(&1.status == :diverged))
    }
  end
end
