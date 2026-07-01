defmodule EvilEngine.DMN.ImportTraceTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias EvilEngine.DMN
  alias EvilEngine.DMN.EvaluationResult
  alias EvilEngine.DMN.EvaluationTrace
  alias EvilEngine.DMN.EvaluationTrace.ImportTrace
  alias EvilEngine.DMN.Evaluator

  @fixtures_dir Path.join([__DIR__, "..", "..", "fixtures", "dmns"])
  @helpers_namespace "https://example.com/dmn/helpers"

  defp read_fixture(name), do: File.read!(Path.join(@fixtures_dir, name))

  defp parse_fixture(name) do
    {:ok, definitions} = DMN.parse_and_validate(read_fixture(name))
    definitions
  end

  defp parse_and_precompile_fixture(name) do
    {:ok, definitions} = DMN.parse_and_validate(read_fixture(name))
    definitions
  end

  defp build_import_resolver(namespace_map) do
    fn namespace ->
      case Map.get(namespace_map, namespace) do
        nil -> {:error, :not_found}
        definitions -> {:ok, definitions}
      end
    end
  end

  defp prepare_importing_model do
    helper = parse_and_precompile_fixture("imported_helper.dmn")
    resolver = build_import_resolver(%{@helpers_namespace => helper})

    {:ok, importing} =
      DMN.parse_and_validate(read_fixture("importing_model.dmn"), import_resolver: resolver)

    {importing, helper, resolver}
  end

  describe "import traces on DecisionTrace" do
    test "single import produces import_traces with correct fields" do
      {importing, _helper, resolver} = prepare_importing_model()

      assert {:ok, %EvaluationResult{result: result, trace: trace}} =
               Evaluator.evaluate(
                 importing,
                 "Decision_final",
                 %{"base" => 5},
                 import_resolver: resolver
               )

      assert result == 20

      final_decision_trace = List.last(trace.decisions)
      assert final_decision_trace.decision_model_id == "Decision_final"
      assert length(final_decision_trace.import_traces) == 1

      [import_trace] = final_decision_trace.import_traces
      assert %ImportTrace{} = import_trace
      assert import_trace.namespace == "https://example.com/dmn/helpers"
      assert import_trace.decision_id == "Decision_double"
      assert import_trace.source_definitions_id == "definitions_helper"
      assert import_trace.result == 10
      assert import_trace.duration_microseconds >= 0

      assert %EvaluationTrace{decisions: nested_decisions} = import_trace.evaluation_trace
      assert nested_decisions != []

      nested_decision = List.last(nested_decisions)
      assert nested_decision.decision_model_id == "Decision_double"
      assert nested_decision.result == 10
    end

    test "decision without imports has empty import_traces" do
      definitions = parse_fixture("simple_unique.dmn")

      assert {:ok, %EvaluationResult{trace: trace}} =
               Evaluator.evaluate(definitions, nil, %{"age" => 25})

      for decision_trace <- trace.decisions do
        assert decision_trace.import_traces == []
      end
    end

    test "ImportTrace.to_json_map/1 serialization includes all fields" do
      {importing, _helper, resolver} = prepare_importing_model()

      assert {:ok, %EvaluationResult{trace: trace}} =
               Evaluator.evaluate(
                 importing,
                 "Decision_final",
                 %{"base" => 5},
                 import_resolver: resolver
               )

      final_trace = List.last(trace.decisions)
      [import_trace] = final_trace.import_traces

      json_map = ImportTrace.to_json_map(import_trace)
      assert json_map[:namespace] == "https://example.com/dmn/helpers"
      assert json_map[:decision_id] == "Decision_double"
      assert json_map[:source_definitions_id] == "definitions_helper"
      assert json_map[:result] == 10
      assert is_integer(json_map[:duration_microseconds])

      assert is_map(json_map[:evaluation_trace])
      assert is_list(json_map[:evaluation_trace][:decisions])
    end

    test "full trace round-trip via EvaluationTrace.to_json_map preserves import_traces" do
      {importing, _helper, resolver} = prepare_importing_model()

      assert {:ok, %EvaluationResult{trace: trace}} =
               Evaluator.evaluate(
                 importing,
                 "Decision_final",
                 %{"base" => 5},
                 import_resolver: resolver
               )

      json_map = EvaluationTrace.to_json_map(trace)
      final_json = List.last(json_map[:decisions])
      assert length(final_json[:import_traces]) == 1

      import_json = hd(final_json[:import_traces])
      assert import_json[:namespace] == "https://example.com/dmn/helpers"
      assert import_json[:decision_id] == "Decision_double"
      assert import_json[:source_definitions_id] == "definitions_helper"
    end

    test "source_definitions_id matches imported model's Definitions.id" do
      {importing, helper, resolver} = prepare_importing_model()

      assert helper.id == "definitions_helper"

      assert {:ok, %EvaluationResult{trace: trace}} =
               Evaluator.evaluate(
                 importing,
                 "Decision_final",
                 %{"base" => 5},
                 import_resolver: resolver
               )

      final_trace = List.last(trace.decisions)
      [import_trace] = final_trace.import_traces
      assert import_trace.source_definitions_id == helper.id
    end
  end
end
