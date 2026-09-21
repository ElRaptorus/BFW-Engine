defmodule BfwEngine.DMN.TypeResolverTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias BfwEngine.DMN.Evaluator
  alias BfwEngine.DMN.Model.Definitions
  alias BfwEngine.DMN.Model.InputData
  alias BfwEngine.DMN.Model.ItemDefinition
  alias BfwEngine.DMN.Model.Output
  alias BfwEngine.DMN.Parser
  alias BfwEngine.DMN.TypeResolver

  @fixtures_dir Path.join([__DIR__, "..", "..", "fixtures", "dmns"])
  defp read_fixture(name), do: File.read!(Path.join(@fixtures_dir, name))

  defp parse_fixture(name) do
    {:ok, definitions} = Parser.parse(read_fixture(name))
    definitions
  end

  describe "resolve_type/2" do
    test "resolves built-in FEEL types" do
      definitions = %Definitions{item_definitions: [], raw_xml: ""}

      assert {:ok, {:builtin, :string}} = TypeResolver.resolve_type("string", definitions)
      assert {:ok, {:builtin, :number}} = TypeResolver.resolve_type("number", definitions)
      assert {:ok, {:builtin, :boolean}} = TypeResolver.resolve_type("boolean", definitions)
      assert {:ok, {:builtin, :date}} = TypeResolver.resolve_type("date", definitions)
      assert {:ok, {:builtin, :time}} = TypeResolver.resolve_type("time", definitions)
      assert {:ok, {:builtin, :dateTime}} = TypeResolver.resolve_type("dateTime", definitions)
      assert {:ok, {:builtin, :dayTimeDuration}} = TypeResolver.resolve_type("dayTimeDuration", definitions)
      assert {:ok, {:builtin, :yearMonthDuration}} = TypeResolver.resolve_type("yearMonthDuration", definitions)
      assert {:ok, {:builtin, :Any}} = TypeResolver.resolve_type("Any", definitions)
    end

    test "resolves custom ItemDefinition by id and name" do
      item_definition = %ItemDefinition{id: "ItemDef_Age", name: "tAge", type_ref: "number"}

      definitions = %Definitions{item_definitions: [item_definition], raw_xml: ""}

      assert {:ok, {:item_definition, ^item_definition}} =
               TypeResolver.resolve_type("ItemDef_Age", definitions)

      assert {:ok, {:item_definition, ^item_definition}} =
               TypeResolver.resolve_type("tAge", definitions)
    end

    test "returns error for unknown typeRef" do
      definitions = %Definitions{item_definitions: [], raw_xml: ""}

      assert {:error, :unknown_type, %{type_ref: "nonexistent"}} =
               TypeResolver.resolve_type("nonexistent", definitions)
    end
  end

  describe "coerce_value/3" do
    test "coerces string to number" do
      definitions = %Definitions{item_definitions: [], raw_xml: ""}

      assert {:ok, 42} = TypeResolver.coerce_value("42", "number", definitions)
      assert {:ok, 3.14} = TypeResolver.coerce_value("3.14", "number", definitions)
    end

    test "passes through already-typed number" do
      definitions = %Definitions{item_definitions: [], raw_xml: ""}

      assert {:ok, 42} = TypeResolver.coerce_value(42, "number", definitions)
      assert {:ok, 3.14} = TypeResolver.coerce_value(3.14, "number", definitions)
    end

    test "coerces boolean strings" do
      definitions = %Definitions{item_definitions: [], raw_xml: ""}

      assert {:ok, true} = TypeResolver.coerce_value("true", "boolean", definitions)
      assert {:ok, false} = TypeResolver.coerce_value("false", "boolean", definitions)
      assert {:ok, true} = TypeResolver.coerce_value(true, "boolean", definitions)
    end

    test "rejects non-numeric string for number type" do
      definitions = %Definitions{item_definitions: [], raw_xml: ""}

      assert {:error, :type_coercion_failed, _} =
               TypeResolver.coerce_value("abc", "number", definitions)
    end

    test "coerces ISO 8601 string to FEEL date" do
      definitions = %Definitions{item_definitions: [], raw_xml: ""}

      assert {:ok, {:feel_date, date_string}} =
               TypeResolver.coerce_value("2025-03-20", "date", definitions)

      assert date_string =~ "2025-03-20"
    end

    test "coerces ISO 8601 string to FEEL time" do
      definitions = %Definitions{item_definitions: [], raw_xml: ""}

      assert {:ok, {:feel_time, _}} =
               TypeResolver.coerce_value("14:30:00", "time", definitions)
    end

    test "coerces ISO 8601 string to FEEL dateTime" do
      definitions = %Definitions{item_definitions: [], raw_xml: ""}

      assert {:ok, {:feel_datetime, _}} =
               TypeResolver.coerce_value("2025-03-20T14:30:00", "dateTime", definitions)
    end

    test "Any type passes through any value" do
      definitions = %Definitions{item_definitions: [], raw_xml: ""}

      assert {:ok, 42} = TypeResolver.coerce_value(42, "Any", definitions)
      assert {:ok, "hello"} = TypeResolver.coerce_value("hello", "Any", definitions)
      assert {:ok, [1, 2]} = TypeResolver.coerce_value([1, 2], "Any", definitions)
    end

    test "validates composite type with named fields" do
      address_type = %ItemDefinition{
        id: "ItemDef_Address",
        name: "tAddress",
        item_components: [
          %ItemDefinition{id: "street", name: "street", type_ref: "string"},
          %ItemDefinition{id: "city", name: "city", type_ref: "string"}
        ]
      }

      definitions = %Definitions{item_definitions: [address_type], raw_xml: ""}

      assert {:ok, %{"street" => "Main St", "city" => "Berlin"}} =
               TypeResolver.coerce_value(
                 %{"street" => "Main St", "city" => "Berlin"},
                 "tAddress",
                 definitions
               )
    end

    test "rejects composite type with missing required field" do
      address_type = %ItemDefinition{
        id: "ItemDef_Address",
        name: "tAddress",
        item_components: [
          %ItemDefinition{id: "street", name: "street", type_ref: "string"},
          %ItemDefinition{id: "city", name: "city", type_ref: "string"}
        ]
      }

      definitions = %Definitions{item_definitions: [address_type], raw_xml: ""}

      assert {:error, :type_coercion_failed, _} =
               TypeResolver.coerce_value(%{"street" => "Main St"}, "tAddress", definitions)
    end

    test "rejects non-map value for composite type" do
      address_type = %ItemDefinition{
        id: "ItemDef_Address",
        name: "tAddress",
        item_components: [
          %ItemDefinition{id: "street", name: "street", type_ref: "string"}
        ]
      }

      definitions = %Definitions{item_definitions: [address_type], raw_xml: ""}

      assert {:error, :type_coercion_failed, _} =
               TypeResolver.coerce_value("not a map", "tAddress", definitions)
    end

    test "wraps single value into list for collection types" do
      tag_list = %ItemDefinition{
        id: "ItemDef_Tags",
        name: "tTagList",
        type_ref: "string",
        is_collection: true
      }

      definitions = %Definitions{item_definitions: [tag_list], raw_xml: ""}

      assert {:ok, ["urgent"]} = TypeResolver.coerce_value("urgent", "tTagList", definitions)
      assert {:ok, ["a", "b"]} = TypeResolver.coerce_value(["a", "b"], "tTagList", definitions)
    end

    test "collection without element type_ref passes through" do
      untyped_list = %ItemDefinition{
        id: "ItemDef_List",
        name: "tList",
        type_ref: nil,
        is_collection: true
      }

      definitions = %Definitions{item_definitions: [untyped_list], raw_xml: ""}

      assert {:ok, [1, "mixed", true]} =
               TypeResolver.coerce_value([1, "mixed", true], "tList", definitions)
    end

    test "rejects value outside allowed_values" do
      age_type = %ItemDefinition{
        id: "ItemDef_Age",
        name: "tAge",
        type_ref: "number",
        allowed_values: "[0..150]"
      }

      definitions = %Definitions{item_definitions: [age_type], raw_xml: ""}

      assert {:ok, 25} = TypeResolver.coerce_value("25", "tAge", definitions)

      assert {:error, :type_coercion_failed, %{input: "tAge", expected: "tAge", got: "200"}} =
               TypeResolver.coerce_value("200", "tAge", definitions)
    end

    test "collection allowed_values rejects individual element violations" do
      rating_list = %ItemDefinition{
        id: "ItemDef_Ratings",
        name: "tRatings",
        type_ref: "number",
        is_collection: true,
        allowed_values: "[1..5]"
      }

      definitions = %Definitions{item_definitions: [rating_list], raw_xml: ""}

      assert {:ok, [1, 3, 5]} = TypeResolver.coerce_value([1, 3, 5], "tRatings", definitions)

      assert {:error, :type_coercion_failed, _} =
               TypeResolver.coerce_value([1, 3, 10], "tRatings", definitions)
    end
  end

  describe "coerce_input_context/2" do
    test "coerces typed InputData entries in context" do
      definitions = parse_fixture("with_input_data.dmn")

      assert {:ok, coerced} =
               TypeResolver.coerce_input_context(definitions, %{
                 "orderAmount" => "750",
                 "isMember" => "true"
               })

      assert coerced["orderAmount"] == 750
      assert coerced["isMember"] == true
    end

    test "skips InputData without typeRef" do
      definitions = %Definitions{
        input_data: [
          %InputData{id: "Input_1", name: "typed", type_ref: "number"},
          %InputData{id: "Input_2", name: "untyped", type_ref: nil}
        ],
        item_definitions: [],
        raw_xml: ""
      }

      assert {:ok, coerced} =
               TypeResolver.coerce_input_context(definitions, %{
                 "typed" => "42",
                 "untyped" => "raw_string"
               })

      assert coerced["typed"] == 42
      assert coerced["untyped"] == "raw_string"
    end

    test "skips missing inputs in context" do
      definitions = %Definitions{
        input_data: [%InputData{id: "Input_1", name: "age", type_ref: "number"}],
        item_definitions: [],
        raw_xml: ""
      }

      assert {:ok, %{}} = TypeResolver.coerce_input_context(definitions, %{})
    end

    test "returns error for unknown InputData typeRef" do
      definitions = %Definitions{
        input_data: [%InputData{id: "Input_1", name: "score", type_ref: "unknown_type"}],
        item_definitions: [],
        raw_xml: ""
      }

      assert {:error, :unknown_type, %{type_ref: "unknown_type"}} =
               TypeResolver.coerce_input_context(definitions, %{"score" => 1})
    end
  end

  describe "value_conforms?/3" do
    test "returns true for matching built-in types" do
      definitions = %Definitions{item_definitions: [], raw_xml: ""}

      assert TypeResolver.value_conforms?("hello", "string", definitions)
      assert TypeResolver.value_conforms?(42, "number", definitions)
      assert TypeResolver.value_conforms?(true, "boolean", definitions)
    end

    test "returns false for mismatched built-in types" do
      definitions = %Definitions{item_definitions: [], raw_xml: ""}

      refute TypeResolver.value_conforms?("hello", "number", definitions)
      refute TypeResolver.value_conforms?(42, "boolean", definitions)
    end

    test "returns true for Any type with any value" do
      definitions = %Definitions{item_definitions: [], raw_xml: ""}

      assert TypeResolver.value_conforms?("anything", "Any", definitions)
      assert TypeResolver.value_conforms?(nil, "Any", definitions)
      assert TypeResolver.value_conforms?(%{}, "Any", definitions)
    end

    test "returns false for unknown type" do
      definitions = %Definitions{item_definitions: [], raw_xml: ""}

      refute TypeResolver.value_conforms?(42, "nonexistent", definitions)
    end

    test "validates collection conformance" do
      list_type = %ItemDefinition{
        id: "ItemDef_Nums",
        name: "tNums",
        type_ref: "number",
        is_collection: true
      }

      definitions = %Definitions{item_definitions: [list_type], raw_xml: ""}

      assert TypeResolver.value_conforms?([1, 2, 3], "tNums", definitions)
      refute TypeResolver.value_conforms?("not a list", "tNums", definitions)
      refute TypeResolver.value_conforms?([1, "two"], "tNums", definitions)
    end
  end

  describe "check_output_types/3" do
    test "returns warning when output value does not match typeRef" do
      definitions = %Definitions{item_definitions: [], raw_xml: ""}
      outputs = [%Output{id: "Output_1", type_ref: "number"}]

      warnings = TypeResolver.check_output_types(%{"output_0" => "not-a-number"}, outputs, definitions)

      assert [%{code: :output_type_mismatch, output_id: "Output_1", expected_type_ref: "number"}] =
               warnings
    end

    test "returns empty list when output conforms" do
      definitions = %Definitions{item_definitions: [], raw_xml: ""}
      outputs = [%Output{id: "Output_1", type_ref: "number"}]

      assert [] = TypeResolver.check_output_types(%{"output_0" => 5}, outputs, definitions)
    end
  end

  describe "integration with Evaluator" do
    test "evaluates decision with string orderAmount coerced to number" do
      definitions = parse_fixture("with_input_data.dmn")

      assert {:ok, result} =
               Evaluator.evaluate(definitions, "Decision_discount_tier", %{
                 "orderAmount" => "750",
                 "isMember" => true
               })

      assert result.result == %{"tier" => "silver"}
    end

    test "invalid string age fails type coercion before evaluation" do
      definitions = parse_fixture("simple_unique.dmn")

      assert {:error, :type_coercion_failed, %{input: "age", expected: "number"}} =
               Evaluator.evaluate(definitions, nil, %{"age" => "twenty-five"})
    end

    test "allowed_values violation fails evaluation" do
      definitions = parse_fixture("item_definitions.dmn")

      assert {:error, :type_coercion_failed, %{input: "customerAge", expected: "tAge"}} =
               Evaluator.evaluate(definitions, nil, %{"customerAge" => "200"})
    end
  end
end
