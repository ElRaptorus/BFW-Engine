defmodule EvilEngine.DMN.BkmTraceTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias EvilEngine.DMN
  alias EvilEngine.DMN.EvaluationResult
  alias EvilEngine.DMN.EvaluationTrace
  alias EvilEngine.DMN.EvaluationTrace.BkmTrace
  alias EvilEngine.DMN.Evaluator
  @fixtures_dir Path.join([__DIR__, "..", "..", "fixtures", "dmns"])
  defp read_fixture(name), do: File.read!(Path.join(@fixtures_dir, name))

  defp parse_and_precompile_fixture(name) do
    {:ok, definitions} = DMN.parse_and_validate(read_fixture(name))
    definitions
  end

  describe "BKM traces on DecisionTrace" do
    test "single BKM invocation produces bkm_traces with expected fields" do
      definitions = parse_and_precompile_fixture("bkm_invocation_table.dmn")

      assert {:ok, %EvaluationResult{result: 40, trace: trace}} =
               Evaluator.evaluate(
                 definitions,
                 "Decision_discount",
                 %{"customerAge" => 70}
               )

      assert [%EvaluationTrace.DecisionTrace{bkm_traces: [bkm_trace]}] = trace.decisions

      assert %BkmTrace{
               bkm_id: "BKM_discount",
               bkm_name: "Discount Logic",
               result: 20,
               duration_microseconds: duration
             } = bkm_trace

      assert duration > 0
      assert bkm_trace.dependent_bkm_traces == []
    end

    test "formal parameter bindings record name and bound value" do
      definitions = parse_and_precompile_fixture("bkm_invocation_literal.dmn")

      assert {:ok, %EvaluationResult{trace: trace}} =
               Evaluator.evaluate(
                 definitions,
                 "Decision_tax",
                 %{"income" => 50_000, "taxRate" => 0.2}
               )

      assert [%EvaluationTrace.DecisionTrace{bkm_traces: [bkm_trace]}] = trace.decisions

      assert [
               %{name: "income", bound_value: 50_000},
               %{name: "taxRate", bound_value: 0.2}
             ] = bkm_trace.formal_parameters
    end

    test "decisions without KnowledgeRequirement edges have empty bkm_traces" do
      definitions = parse_and_precompile_fixture("simple_unique.dmn")

      assert {:ok, %EvaluationResult{trace: trace}} =
               Evaluator.evaluate(definitions, nil, %{"age" => 25})

      assert [%EvaluationTrace.DecisionTrace{bkm_traces: []}] = trace.decisions
    end

    # Nested BKM fixture: bkm_chain.dmn (BKM_derived invokes BKM_base via knowledgeRequirement).
    test "nested BKM chain records dependent_bkm_traces on the outer BkmTrace" do
      definitions = parse_and_precompile_fixture("bkm_chain.dmn")

      assert {:ok, %EvaluationResult{result: 38, trace: trace}} =
               Evaluator.evaluate(definitions, "Decision_main", %{"n" => 3, "m" => 7})

      assert [%EvaluationTrace.DecisionTrace{bkm_traces: [outer_trace]}] = trace.decisions

      assert %BkmTrace{
               bkm_id: "BKM_derived",
               bkm_name: "Derived Logic",
               result: 37,
               dependent_bkm_traces: [inner_trace]
             } = outer_trace

      assert %BkmTrace{
               bkm_id: "BKM_base",
               bkm_name: "Base Logic",
               result: 30,
               formal_parameters: [%{name: "n", bound_value: 3}]
             } = inner_trace
    end
  end

  describe "BkmTrace.to_json_map/1" do
    test "serializes all trace fields for JSON output" do
      trace = %BkmTrace{
        bkm_id: "BKM_discount",
        bkm_name: "Discount Logic",
        formal_parameters: [%{name: "customerAge", bound_value: 70}],
        result: 20,
        duration_microseconds: 42,
        dependent_bkm_traces: [
          %BkmTrace{
            bkm_id: "BKM_base",
            bkm_name: "Base Logic",
            formal_parameters: [%{name: "n", bound_value: 3}],
            result: 30,
            duration_microseconds: 10,
            dependent_bkm_traces: []
          }
        ]
      }

      json_map = BkmTrace.to_json_map(trace)

      assert json_map == %{
               bkm_id: "BKM_discount",
               bkm_name: "Discount Logic",
               formal_parameters: [%{name: "customerAge", bound_value: 70}],
               result: 20,
               duration_microseconds: 42,
               dependent_bkm_traces: [
                 %{
                   bkm_id: "BKM_base",
                   bkm_name: "Base Logic",
                   formal_parameters: [%{name: "n", bound_value: 3}],
                   result: 30,
                   duration_microseconds: 10,
                   dependent_bkm_traces: []
                 }
               ]
             }
    end

    test "round-trip through DecisionTrace.to_json_map includes bkm_traces" do
      decision_trace = %EvaluationTrace.DecisionTrace{
        decision_model_id: "Decision_discount",
        decision_name: "Discount Decision",
        hit_policy: :unique,
        result: 40,
        duration_microseconds: 100,
        bkm_traces: [
          %BkmTrace{
            bkm_id: "BKM_discount",
            bkm_name: "Discount Logic",
            formal_parameters: [%{name: "customerAge", bound_value: 70}],
            result: 20,
            duration_microseconds: 50
          }
        ]
      }

      json_map = EvaluationTrace.DecisionTrace.to_json_map(decision_trace)

      assert [bkm_json] = json_map.bkm_traces

      assert bkm_json == %{
               bkm_id: "BKM_discount",
               bkm_name: "Discount Logic",
               formal_parameters: [%{name: "customerAge", bound_value: 70}],
               result: 20,
               duration_microseconds: 50,
               dependent_bkm_traces: []
             }
    end
  end
end
