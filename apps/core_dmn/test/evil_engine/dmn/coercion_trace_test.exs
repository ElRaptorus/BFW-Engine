defmodule EvilEngine.DMN.CoercionTraceTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias EvilEngine.DMN
  alias EvilEngine.DMN.EvaluationResult
  alias EvilEngine.DMN.EvaluationTrace
  alias EvilEngine.DMN.EvaluationTrace.CoercionTrace
  alias EvilEngine.DMN.Evaluator
  alias EvilEngine.DMN.Model.Definitions
  alias EvilEngine.DMN.Model.InputData
  alias EvilEngine.DMN.Parser
  alias EvilEngine.DMN.TypeResolver

  @fixtures_dir Path.join([__DIR__, "..", "..", "fixtures", "dmns"])
  defp read_fixture(name), do: File.read!(Path.join(@fixtures_dir, name))

  defp parse_fixture(name) do
    {:ok, definitions} = Parser.parse(read_fixture(name))
    definitions
  end

  defp parse_and_precompile_fixture(name) do
    {:ok, definitions} = DMN.parse_and_validate(read_fixture(name))
    definitions
  end

  describe "TypeResolver.coerce_input_context_with_trace/2" do
    test "string to number coercion records coerced true with original and coerced values" do
      definitions = %Definitions{
        input_data: [%InputData{id: "Input_1", name: "orderAmount", type_ref: "number"}],
        item_definitions: [],
        raw_xml: ""
      }

      assert {:ok, coerced_context, traces} =
               TypeResolver.coerce_input_context_with_trace(definitions, %{
                 "orderAmount" => "750"
               })

      assert coerced_context["orderAmount"] == 750

      assert [
               %CoercionTrace{
                 input_name: "orderAmount",
                 original_value: "750",
                 coerced_value: 750,
                 target_type: "number",
                 coerced: true
               }
             ] = traces
    end

    test "value already correct type records coerced false with equal original and coerced" do
      definitions = %Definitions{
        input_data: [%InputData{id: "Input_1", name: "orderAmount", type_ref: "number"}],
        item_definitions: [],
        raw_xml: ""
      }

      assert {:ok, coerced_context, traces} =
               TypeResolver.coerce_input_context_with_trace(definitions, %{
                 "orderAmount" => 750
               })

      assert coerced_context["orderAmount"] == 750

      assert [
               %CoercionTrace{
                 input_name: "orderAmount",
                 original_value: 750,
                 coerced_value: 750,
                 target_type: "number",
                 coerced: false
               }
             ] = traces
    end

    test "missing input produces no trace entry" do
      definitions = %Definitions{
        input_data: [%InputData{id: "Input_1", name: "orderAmount", type_ref: "number"}],
        item_definitions: [],
        raw_xml: ""
      }

      assert {:ok, %{}, []} =
               TypeResolver.coerce_input_context_with_trace(definitions, %{})
    end

    test "input without type_ref produces no trace entry" do
      definitions = %Definitions{
        input_data: [
          %InputData{id: "Input_1", name: "typed", type_ref: "number"},
          %InputData{id: "Input_2", name: "untyped", type_ref: nil}
        ],
        item_definitions: [],
        raw_xml: ""
      }

      assert {:ok, coerced_context, traces} =
               TypeResolver.coerce_input_context_with_trace(definitions, %{
                 "typed" => "42",
                 "untyped" => "raw_string"
               })

      assert coerced_context["typed"] == 42
      assert coerced_context["untyped"] == "raw_string"

      assert [
               %CoercionTrace{input_name: "typed", coerced: true}
             ] = traces
    end

    test "with_input_data fixture coerces orderAmount and isMember with traces" do
      definitions = parse_fixture("with_input_data.dmn")

      assert {:ok, coerced_context, traces} =
               TypeResolver.coerce_input_context_with_trace(definitions, %{
                 "customerName" => "Alice",
                 "orderAmount" => "1000",
                 "isMember" => "true"
               })

      assert coerced_context["orderAmount"] == 1000
      assert coerced_context["isMember"] == true
      assert coerced_context["customerName"] == "Alice"

      trace_by_name = Map.new(traces, &{&1.input_name, &1})

      assert trace_by_name["orderAmount"].coerced == true
      assert trace_by_name["orderAmount"].original_value == "1000"
      assert trace_by_name["orderAmount"].coerced_value == 1000

      assert trace_by_name["isMember"].coerced == true
      assert trace_by_name["isMember"].original_value == "true"
      assert trace_by_name["isMember"].coerced_value == true

      assert trace_by_name["customerName"].coerced == false
      assert trace_by_name["customerName"].original_value == "Alice"
      assert trace_by_name["customerName"].coerced_value == "Alice"
    end
  end

  describe "CoercionTrace.to_json_map/1" do
    test "serializes all trace fields for JSON output" do
      trace = %CoercionTrace{
        input_name: "orderAmount",
        original_value: "750",
        coerced_value: 750,
        target_type: "number",
        coerced: true
      }

      assert CoercionTrace.to_json_map(trace) == %{
               input_name: "orderAmount",
               original_value: "750",
               coerced_value: 750,
               target_type: "number",
               coerced: true
             }
    end
  end

  describe "evaluator end-to-end input_coercions" do
    test "EvaluationTrace includes input_coercions from typed InputData in the model" do
      definitions = parse_and_precompile_fixture("with_input_data.dmn")

      assert {:ok, %EvaluationResult{trace: trace}} =
               Evaluator.evaluate(definitions, "Decision_greeting", %{
                 "customerName" => "Bob",
                 "orderAmount" => "500",
                 "isMember" => "false"
               })

      trace_by_name = Map.new(trace.input_coercions, &{&1.input_name, &1})

      assert trace_by_name["orderAmount"].coerced == true
      assert trace_by_name["orderAmount"].original_value == "500"
      assert trace_by_name["orderAmount"].coerced_value == 500
      assert trace_by_name["orderAmount"].target_type == "number"

      assert trace_by_name["isMember"].coerced == true
      assert trace_by_name["isMember"].original_value == "false"
      assert trace_by_name["isMember"].coerced_value == false

      assert trace_by_name["customerName"].coerced == false
      assert trace_by_name["customerName"].original_value == "Bob"
      assert trace_by_name["customerName"].coerced_value == "Bob"
    end

    test "EvaluationTrace.to_json_map includes input_coercions" do
      definitions = parse_and_precompile_fixture("with_input_data.dmn")

      assert {:ok, %EvaluationResult{trace: trace}} =
               Evaluator.evaluate(definitions, "Decision_discount_tier", %{
                 "orderAmount" => 1200,
                 "isMember" => true
               })

      json_map = EvaluationTrace.to_json_map(trace)

      assert length(json_map.input_coercions) == 2

      order_amount_json = Enum.find(json_map.input_coercions, &(&1.input_name == "orderAmount"))

      assert order_amount_json.coerced == false
      assert order_amount_json.original_value == 1200
      assert order_amount_json.coerced_value == 1200
    end
  end
end
