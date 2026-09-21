defmodule BfwEngine.DMN.HitPoliciesTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias BfwEngine.DMN.EvaluationResult
  alias BfwEngine.DMN.Evaluator
  alias BfwEngine.DMN.Parser

  @fixtures_dir Path.join([__DIR__, "..", "..", "fixtures", "dmns"])
  defp read_fixture(name), do: File.read!(Path.join(@fixtures_dir, name))

  defp parse_fixture(name) do
    {:ok, definitions} = Parser.parse(read_fixture(name))
    definitions
  end

  # =========================================================================
  # UNIQUE hit policy
  # =========================================================================

  describe "UNIQUE hit policy" do
    test "single match returns the matched output value" do
      definitions = parse_fixture("simple_unique.dmn")
      {:ok, result} = Evaluator.evaluate(definitions, nil, %{"age" => 25})
      assert result.hit_policy == :unique
      assert result.result == %{"discount" => 5}
    end

    test "matched_rules contains exactly one rule ID on single match" do
      definitions = parse_fixture("simple_unique.dmn")
      {:ok, result} = Evaluator.evaluate(definitions, nil, %{"age" => 25})
      assert length(result.matched_rules) == 1
    end

    test "different input values hit different rules with correct outputs" do
      definitions = parse_fixture("simple_unique.dmn")

      {:ok, young} = Evaluator.evaluate(definitions, nil, %{"age" => 10})
      assert young.result == %{"discount" => 10}

      {:ok, adult} = Evaluator.evaluate(definitions, nil, %{"age" => 25})
      assert adult.result == %{"discount" => 5}

      {:ok, senior} = Evaluator.evaluate(definitions, nil, %{"age" => 70})
      assert senior.result == %{"discount" => 15}
    end

    test "returns nil result when no rule matches" do
      definitions = parse_fixture("unique_violation.dmn")
      {:ok, result} = Evaluator.evaluate(definitions, nil, %{"value" => -5})
      assert result.hit_policy == :unique
      assert result.result == nil
    end

    test "returns violation error when more than one rule matches" do
      definitions = parse_fixture("unique_violation.dmn")

      assert {:error, :hit_policy_violation, %{policy: :unique, message: message}} =
               Evaluator.evaluate(definitions, nil, %{"value" => 10})

      assert message =~ "UNIQUE"
    end
  end

  # =========================================================================
  # FIRST hit policy
  # =========================================================================

  describe "FIRST hit policy" do
    test "returns first matching rule's output when multiple could match" do
      definitions = parse_fixture("multi_input_first.dmn")

      {:ok, result} =
        Evaluator.evaluate(definitions, nil, %{
          "income" => 20_000,
          "creditScore" => 500,
          "yearsEmployed" => 1
        })

      assert result.hit_policy == :first
      assert result.result == %{"riskCategory" => "high"}
    end

    test "first hit policy matched_rules contains exactly one entry" do
      definitions = parse_fixture("multi_input_first.dmn")

      {:ok, result} =
        Evaluator.evaluate(definitions, nil, %{
          "income" => 20_000,
          "creditScore" => 500,
          "yearsEmployed" => 1
        })

      assert length(result.matched_rules) == 1
      assert hd(result.matched_rules) == "Rule_high_risk"
    end

    test "returns nil when no rules match" do
      definitions = parse_fixture("multi_input_first.dmn")

      {:ok, result} =
        Evaluator.evaluate(definitions, nil, %{
          "income" => 100_000,
          "creditScore" => 500,
          "yearsEmployed" => 1
        })

      assert result.hit_policy == :first
      assert result.result == nil
    end

    test "returns first rule in document order from all_hit_policies fixture" do
      definitions = parse_fixture("all_hit_policies.dmn")

      {:ok, result} =
        Evaluator.evaluate(definitions, "Decision_first", %{"value" => 5})

      assert result.hit_policy == :first
      assert result.result == %{"result" => "first_match"}
    end
  end

  # =========================================================================
  # ANY hit policy
  # =========================================================================

  describe "ANY hit policy" do
    test "succeeds when all matching rules produce the same output" do
      definitions = parse_fixture("any_same_output.dmn")

      {:ok, result} = Evaluator.evaluate(definitions, nil, %{"value" => 10})
      assert result.hit_policy == :any
      assert result.result == %{"result" => "positive"}
    end

    test "returns violation when matching rules produce different outputs" do
      definitions = parse_fixture("all_hit_policies.dmn")

      assert {:error, :hit_policy_violation, %{policy: :any, message: message}} =
               Evaluator.evaluate(definitions, "Decision_any", %{"value" => 10})

      assert message =~ "different outputs"
    end

    test "returns nil when no rules match" do
      definitions = parse_fixture("any_same_output.dmn")

      {:ok, result} = Evaluator.evaluate(definitions, nil, %{"value" => -5})
      assert result.hit_policy == :any
      assert result.result == nil
    end
  end

  # =========================================================================
  # COLLECT hit policy
  # =========================================================================

  describe "COLLECT hit policy" do
    test "COLLECT with SUM aggregation returns numeric sum" do
      definitions = parse_fixture("collect_with_sum.dmn")

      {:ok, result} = Evaluator.evaluate(definitions, nil, %{"category" => "electronics"})
      assert result.hit_policy == :collect
      assert result.result == 15
    end

    test "COLLECT with SUM aggregation for single match" do
      definitions = parse_fixture("collect_with_sum.dmn")

      {:ok, result} = Evaluator.evaluate(definitions, nil, %{"category" => "premium"})
      assert result.hit_policy == :collect
      assert result.result == 25
    end

    test "COLLECT without aggregation returns list of output maps" do
      definitions = parse_fixture("all_hit_policies.dmn")

      {:ok, result} =
        Evaluator.evaluate(definitions, "Decision_collect", %{"value" => 5})

      assert result.hit_policy == :collect
      assert is_list(result.result)
      assert length(result.result) == 2
      assert Enum.at(result.result, 0) == %{"result" => 1}
      assert Enum.at(result.result, 1) == %{"result" => 2}
    end

    test "COLLECT with COUNT aggregation returns number of matched rules" do
      definitions = parse_fixture("collect_count.dmn")

      {:ok, result} = Evaluator.evaluate(definitions, nil, %{"category" => "electronics"})
      assert result.hit_policy == :collect
      assert result.result == 3
    end

    test "COLLECT with COUNT returns 1 for single match" do
      definitions = parse_fixture("collect_count.dmn")

      {:ok, result} = Evaluator.evaluate(definitions, nil, %{"category" => "clothing"})
      assert result.hit_policy == :collect
      assert result.result == 1
    end

    test "COLLECT with COUNT returns 0 when no rules match" do
      definitions = parse_fixture("collect_count.dmn")

      {:ok, result} = Evaluator.evaluate(definitions, nil, %{"category" => "unknown"})
      assert result.hit_policy == :collect
      assert result.result == 0
    end

    test "COLLECT with MIN aggregation returns smallest numeric value" do
      definitions = parse_fixture("collect_min.dmn")

      {:ok, result} = Evaluator.evaluate(definitions, nil, %{"category" => "electronics"})
      assert result.hit_policy == :collect
      assert result.result == 10
    end

    test "COLLECT with MIN returns single value for single match" do
      definitions = parse_fixture("collect_min.dmn")

      {:ok, result} = Evaluator.evaluate(definitions, nil, %{"category" => "clothing"})
      assert result.hit_policy == :collect
      assert result.result == 20
    end

    test "COLLECT with MIN returns nil when no rules match" do
      definitions = parse_fixture("collect_min.dmn")

      {:ok, result} = Evaluator.evaluate(definitions, nil, %{"category" => "unknown"})
      assert result.hit_policy == :collect
      assert result.result == nil
    end

    test "COLLECT with MAX aggregation returns largest numeric value" do
      definitions = parse_fixture("collect_max.dmn")

      {:ok, result} = Evaluator.evaluate(definitions, nil, %{"category" => "electronics"})
      assert result.hit_policy == :collect
      assert result.result == 50
    end

    test "COLLECT with MAX returns single value for single match" do
      definitions = parse_fixture("collect_max.dmn")

      {:ok, result} = Evaluator.evaluate(definitions, nil, %{"category" => "clothing"})
      assert result.hit_policy == :collect
      assert result.result == 20
    end

    test "COLLECT with MAX returns nil when no rules match" do
      definitions = parse_fixture("collect_max.dmn")

      {:ok, result} = Evaluator.evaluate(definitions, nil, %{"category" => "unknown"})
      assert result.hit_policy == :collect
      assert result.result == nil
    end
  end

  # =========================================================================
  # RULE ORDER hit policy
  # =========================================================================

  describe "RULE ORDER hit policy" do
    test "returns all matching rules in document order" do
      definitions = parse_fixture("all_hit_policies.dmn")

      {:ok, result} =
        Evaluator.evaluate(definitions, "Decision_rule_order", %{"value" => 5})

      assert result.hit_policy == :rule_order
      assert is_list(result.result)
      assert length(result.result) == 2
      assert Enum.at(result.result, 0) == %{"result" => "rule_a"}
      assert Enum.at(result.result, 1) == %{"result" => "rule_b"}
    end

    test "multi-output RULE ORDER preserves multiple output columns" do
      definitions = parse_fixture("multi_output_rule_order.dmn")

      {:ok, result} =
        Evaluator.evaluate(definitions, nil, %{"amount" => 1500, "region" => "EU"})

      assert result.hit_policy == :rule_order
      assert is_list(result.result)
      assert length(result.result) == 1

      [first] = result.result
      assert Map.has_key?(first, "warehouse")
      assert Map.has_key?(first, "priority")
      assert Map.has_key?(first, "fee")
    end
  end

  # =========================================================================
  # OUTPUT ORDER hit policy
  # =========================================================================

  describe "OUTPUT ORDER hit policy" do
    test "sorts results by output priority list" do
      definitions = parse_fixture("all_hit_policies.dmn")

      {:ok, result} =
        Evaluator.evaluate(definitions, "Decision_output_order", %{"value" => 5})

      assert result.hit_policy == :output_order
      assert is_list(result.result)
      assert length(result.result) == 2

      output_values = Enum.map(result.result, & &1["grade"])
      assert output_values == ["A", "B"]
    end
  end

  # =========================================================================
  # PRIORITY hit policy
  # =========================================================================

  describe "PRIORITY hit policy" do
    test "returns highest-priority output from matching rules" do
      definitions = parse_fixture("all_hit_policies.dmn")

      {:ok, result} =
        Evaluator.evaluate(definitions, "Decision_priority", %{"value" => 5})

      assert result.hit_policy == :priority
      assert result.result == %{"severity" => "critical"}
    end

    test "returns nil when no rules match" do
      definitions = parse_fixture("all_hit_policies.dmn")

      {:ok, result} =
        Evaluator.evaluate(definitions, "Decision_priority", %{"value" => -10})

      assert result.hit_policy == :priority
      assert result.result == nil
    end

    test "priority from dedicated fixture returns highest-priority level" do
      definitions = parse_fixture("priority_hit_policy.dmn")

      {:ok, result} = Evaluator.evaluate(definitions, nil, %{"score" => 95})
      assert result.hit_policy == :priority
      assert result.result == %{"level" => "critical"}
    end
  end

  # =========================================================================
  # Literal Expression (G8)
  # =========================================================================

  describe "Literal Expression (G8)" do
    test "evaluates FEEL expression directly and returns result" do
      definitions = parse_fixture("literal_expression.dmn")
      {:ok, result} = Evaluator.evaluate(definitions, nil, %{"x" => 10, "y" => 20})
      assert result.hit_policy == :literal
      assert result.result == 30
    end

    test "literal expression trace has no matched rules" do
      definitions = parse_fixture("literal_expression.dmn")
      {:ok, result} = Evaluator.evaluate(definitions, nil, %{"x" => 10, "y" => 20})
      [decision_trace] = result.trace.decisions
      assert decision_trace.hit_policy == :literal
      assert decision_trace.matched_rules == []
    end

    test "literal expression trace records input context as input traces" do
      definitions = parse_fixture("literal_expression.dmn")
      {:ok, result} = Evaluator.evaluate(definitions, nil, %{"x" => 10, "y" => 20})
      [decision_trace] = result.trace.decisions
      assert decision_trace.inputs != []
    end
  end

  # =========================================================================
  # Trace completeness
  # =========================================================================

  describe "Trace completeness" do
    test "trace contains input traces with resolved values" do
      definitions = parse_fixture("simple_unique.dmn")
      {:ok, result} = Evaluator.evaluate(definitions, nil, %{"age" => 25})
      [decision_trace] = result.trace.decisions
      assert decision_trace.inputs != []
      [input_trace] = decision_trace.inputs
      assert input_trace.resolved_value == 25
      assert input_trace.input_id != nil
    end

    test "unmatched_rules_count is accurate" do
      definitions = parse_fixture("simple_unique.dmn")
      {:ok, result} = Evaluator.evaluate(definitions, nil, %{"age" => 25})
      [decision_trace] = result.trace.decisions
      assert decision_trace.unmatched_rules_count == 2
    end

    test "include_unmatched_details adds full traces for all rules" do
      definitions = parse_fixture("simple_unique.dmn")

      {:ok, result} =
        Evaluator.evaluate(definitions, nil, %{"age" => 25}, include_unmatched_details: true)

      [decision_trace] = result.trace.decisions
      assert length(decision_trace.matched_rules) == 1
      assert length(decision_trace.unmatched_rules) == 2
      assert decision_trace.unmatched_rules_count == 2

      Enum.each(decision_trace.unmatched_rules, fn rule_trace ->
        assert rule_trace.output_values == %{}
        assert rule_trace.input_evaluations != []
      end)
    end

    test "duration_microseconds is a positive integer" do
      definitions = parse_fixture("simple_unique.dmn")
      {:ok, result} = Evaluator.evaluate(definitions, nil, %{"age" => 25})
      assert is_integer(result.duration_microseconds)
      assert result.duration_microseconds > 0
    end

    test "decision_trace contains timing information" do
      definitions = parse_fixture("simple_unique.dmn")
      {:ok, result} = Evaluator.evaluate(definitions, nil, %{"age" => 25})
      [decision_trace] = result.trace.decisions
      assert is_integer(decision_trace.duration_microseconds)
      assert decision_trace.duration_microseconds >= 0
    end
  end

  # =========================================================================
  # EvaluationResult.to_json_map/1
  # =========================================================================

  describe "EvaluationResult.to_json_map/1" do
    test "produces a JSON-serializable map" do
      definitions = parse_fixture("simple_unique.dmn")
      {:ok, result} = Evaluator.evaluate(definitions, nil, %{"age" => 25})
      json_map = EvaluationResult.to_json_map(result)
      assert {:ok, _json} = Jason.encode(json_map)
    end

    test "hit_policy is serialized as string" do
      definitions = parse_fixture("simple_unique.dmn")
      {:ok, result} = Evaluator.evaluate(definitions, nil, %{"age" => 25})
      json_map = EvaluationResult.to_json_map(result)
      assert is_binary(json_map.hit_policy)
    end

    test "evaluated_at is an ISO8601 string" do
      definitions = parse_fixture("simple_unique.dmn")
      {:ok, result} = Evaluator.evaluate(definitions, nil, %{"age" => 25})
      json_map = EvaluationResult.to_json_map(result)
      assert is_binary(json_map.evaluated_at)
      assert String.contains?(json_map.evaluated_at, "T")
    end
  end

  # =========================================================================
  # Multiple decisions in same model
  # =========================================================================

  describe "Multiple decisions in same model" do
    test "evaluates specific decision by ID from multi-decision model" do
      definitions = parse_fixture("all_hit_policies.dmn")

      {:ok, result} =
        Evaluator.evaluate(definitions, "Decision_unique", %{"value" => 5})

      assert result.decision_model_id == "Decision_unique"
      assert result.result == %{"result" => "low"}
    end

    test "returns ambiguous error when multiple decisions and no ID specified" do
      definitions = parse_fixture("all_hit_policies.dmn")

      assert {:error, :ambiguous_decision, %{message: _message}} =
               Evaluator.evaluate(definitions, nil, %{"value" => 5})
    end
  end

  # =========================================================================
  # Default output entry (no-match fallback)
  # =========================================================================

  describe "defaultOutputEntry" do
    test "single-output table returns default value when no rules match" do
      definitions = parse_fixture("default_output_entry.dmn")

      {:ok, result} =
        Evaluator.evaluate(definitions, "Decision_default_single", %{"status" => "nonexistent"})

      assert result.result == "unknown"
    end

    test "single-output table returns matched output when a rule matches" do
      definitions = parse_fixture("default_output_entry.dmn")

      {:ok, result} =
        Evaluator.evaluate(definitions, "Decision_default_single", %{"status" => "active"})

      assert result.result == %{"category" => "premium"}
    end

    test "multi-output table returns default values map when no rules match" do
      definitions = parse_fixture("default_output_entry.dmn")

      {:ok, result} =
        Evaluator.evaluate(definitions, "Decision_default_multi", %{"status" => "nonexistent"})

      assert result.result == %{"tier" => "free", "limit" => 0}
    end

    test "table without defaults returns nil when no rules match (backward compat)" do
      definitions = parse_fixture("default_output_entry.dmn")

      {:ok, result} =
        Evaluator.evaluate(definitions, "Decision_no_default", %{"status" => "nonexistent"})

      assert result.result == nil
    end

    test "partial defaults — columns without default return nil per column" do
      definitions = parse_fixture("default_output_entry.dmn")

      {:ok, result} =
        Evaluator.evaluate(definitions, "Decision_default_partial", %{"status" => "nonexistent"})

      assert result.result == %{"tier" => "basic", "code" => nil}
    end

    test "FIRST hit policy uses defaults on no match" do
      definitions = parse_fixture("default_output_entry.dmn")

      {:ok, result} =
        Evaluator.evaluate(definitions, "Decision_default_partial", %{"status" => "none"})

      assert result.result == %{"tier" => "basic", "code" => nil}
    end
  end
end
