defmodule EvilEngine.DMN.EnrichmentTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias EvilEngine.DMN
  alias EvilEngine.DMN.EvaluationResult
  alias EvilEngine.DMN.EvaluationTrace.RuleTrace
  alias EvilEngine.DMN.Evaluator

  @fixtures_dir Path.join([__DIR__, "..", "..", "fixtures", "dmns"])
  defp read_fixture(name), do: File.read!(Path.join(@fixtures_dir, name))

  @simple_unique_definitions_id "definitions_discount"
  @simple_unique_namespace "https://example.com/dmn/discount"

  @all_hit_policies_definitions_id "definitions_hit_policies"
  @all_hit_policies_namespace "https://example.com/dmn/hit-policies"

  defp parse_and_validate_fixture(name) do
    {:ok, definitions} = DMN.parse_and_validate(read_fixture(name))
    definitions
  end

  defp evaluate_simple_unique(input_context, opts \\ []) do
    definitions = parse_and_validate_fixture("simple_unique.dmn")
    Evaluator.evaluate(definitions, nil, input_context, opts)
  end

  defp first_matched_rule_trace(%EvaluationResult{} = result) do
    [%{matched_rules: [rule_trace | _]}] = result.trace.decisions
    rule_trace
  end

  describe "EvaluationResult enrichment fields" do
    test "contains definitions_id matching the parsed model" do
      {:ok, result} = evaluate_simple_unique(%{"age" => 25})

      assert result.definitions_id == @simple_unique_definitions_id
    end

    test "contains definitions_namespace matching the parsed model" do
      {:ok, result} = evaluate_simple_unique(%{"age" => 25})

      assert result.definitions_namespace == @simple_unique_namespace
    end

    test "all_hit_policies fixture exposes expected definitions id and namespace" do
      definitions = parse_and_validate_fixture("all_hit_policies.dmn")

      assert definitions.id == @all_hit_policies_definitions_id
      assert definitions.namespace == @all_hit_policies_namespace

      {:ok, result} =
        Evaluator.evaluate(definitions, "Decision_unique", %{"value" => 5})

      assert result.definitions_id == @all_hit_policies_definitions_id
      assert result.definitions_namespace == @all_hit_policies_namespace
    end

    test "contains decision_version_id when passed via opts" do
      {:ok, result} =
        evaluate_simple_unique(%{"age" => 25}, decision_version_id: "version-abc-123")

      assert result.decision_version_id == "version-abc-123"
    end

    test "decision_version_id is nil for ad-hoc evaluations without the opt" do
      {:ok, result} = evaluate_simple_unique(%{"age" => 25})

      assert result.decision_version_id == nil
    end
  end

  describe "RuleTrace.output_values named columns" do
    test "uses Output.name as key when available" do
      {:ok, result} = evaluate_simple_unique(%{"age" => 25})

      rule_trace = first_matched_rule_trace(result)

      assert %RuleTrace{output_values: %{"discount" => 5}} = rule_trace
    end

    test "uses Output.label as fallback when name is absent" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <definitions xmlns="https://www.omg.org/spec/DMN/20191111/MODEL/"
        id="definitions_label_only" name="Label Only Output"
        namespace="https://example.com/dmn/label-only">
        <inputData id="InputData_value" name="value">
          <variable name="value" typeRef="number"/>
        </inputData>
        <decision id="Decision_label_only" name="Label Only">
          <informationRequirement id="ir_value">
            <requiredInput href="#InputData_value"/>
          </informationRequirement>
          <decisionTable id="dt_label_only" hitPolicy="UNIQUE">
            <input id="Input_value" label="Value">
              <inputExpression typeRef="number">value</inputExpression>
            </input>
            <output id="Output_result" label="ResultLabel" typeRef="number"/>
            <rule id="Rule_positive">
              <inputEntry id="IE_positive"><text>&gt; 0</text></inputEntry>
              <outputEntry id="OE_positive"><text>42</text></outputEntry>
            </rule>
          </decisionTable>
        </decision>
      </definitions>
      """

      {:ok, definitions} = DMN.parse_and_validate(xml)
      {:ok, result} = Evaluator.evaluate(definitions, nil, %{"value" => 1})

      rule_trace = first_matched_rule_trace(result)

      assert %RuleTrace{output_values: %{"ResultLabel" => 42}} = rule_trace
    end

    test "uses output_N when both name and label are absent" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <definitions xmlns="https://www.omg.org/spec/DMN/20191111/MODEL/"
        id="definitions_positional" name="Positional Output"
        namespace="https://example.com/dmn/positional">
        <inputData id="InputData_value" name="value">
          <variable name="value" typeRef="number"/>
        </inputData>
        <decision id="Decision_positional" name="Positional">
          <informationRequirement id="ir_value">
            <requiredInput href="#InputData_value"/>
          </informationRequirement>
          <decisionTable id="dt_positional" hitPolicy="UNIQUE">
            <input id="Input_value" label="Value">
              <inputExpression typeRef="number">value</inputExpression>
            </input>
            <output id="Output_unnamed" typeRef="number"/>
            <rule id="Rule_positive">
              <inputEntry id="IE_positive"><text>&gt; 0</text></inputEntry>
              <outputEntry id="OE_positive"><text>99</text></outputEntry>
            </rule>
          </decisionTable>
        </decision>
      </definitions>
      """

      {:ok, definitions} = DMN.parse_and_validate(xml)
      {:ok, result} = Evaluator.evaluate(definitions, nil, %{"value" => 1})

      rule_trace = first_matched_rule_trace(result)

      assert %RuleTrace{output_values: %{"output_0" => 99}} = rule_trace
    end
  end

  describe "EvaluationResult.to_json_map/1" do
    test "includes all enrichment fields" do
      {:ok, result} =
        evaluate_simple_unique(%{"age" => 25}, decision_version_id: "version-json-1")

      json_map = EvaluationResult.to_json_map(result)

      assert json_map.definitions_id == @simple_unique_definitions_id
      assert json_map.definitions_namespace == @simple_unique_namespace
      assert json_map.decision_version_id == "version-json-1"
    end

    test "includes nil enrichment fields for ad-hoc evaluation" do
      {:ok, result} = evaluate_simple_unique(%{"age" => 25})

      json_map = EvaluationResult.to_json_map(result)

      assert json_map.definitions_id == @simple_unique_definitions_id
      assert json_map.definitions_namespace == @simple_unique_namespace
      assert json_map.decision_version_id == nil
    end
  end
end
