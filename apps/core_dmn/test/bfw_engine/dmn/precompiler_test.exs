defmodule BfwEngine.DMN.PrecompilerTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias BfwEngine.DMN
  alias BfwEngine.DMN.Model.BoxedContext
  alias BfwEngine.DMN.Model.BoxedEvery
  alias BfwEngine.DMN.Model.BoxedFor
  alias BfwEngine.DMN.Model.BoxedSome
  alias BfwEngine.DMN.Model.DecisionTable
  alias BfwEngine.DMN.Model.FunctionDefinition
  alias BfwEngine.DMN.Model.InputEntry
  alias BfwEngine.DMN.Model.LiteralExpression
  alias BfwEngine.DMN.Model.OutputEntry
  alias BfwEngine.DMN.Parser
  alias BfwEngine.DMN.Precompiler

  @fixtures_dir Path.join([__DIR__, "..", "..", "fixtures", "dmns"])
  defp read_fixture(name), do: File.read!(Path.join(@fixtures_dir, name))

  describe "precompile/1" do
    test "decision table inputs, rules, and outputs receive compiled references" do
      {:ok, definitions} = DMN.parse_and_validate(read_fixture("simple_unique.dmn"))
      [decision] = definitions.decisions
      table = decision.expression

      assert %InputEntry{compiled_ref: reference} = hd(hd(table.rules).input_entries)
      assert is_reference(reference)

      [input | _] = table.inputs
      assert is_reference(input.compiled_expression_ref)

      assert %OutputEntry{compiled_ref: output_reference} =
               hd(hd(table.rules).output_entries)

      assert is_reference(output_reference)
    end

    test "literal expression decision receives compiled reference" do
      {:ok, definitions} = DMN.parse_and_validate(read_fixture("literal_expression.dmn"))
      [decision] = definitions.decisions

      assert %LiteralExpression{compiled_ref: reference} = decision.expression
      assert is_reference(reference)
    end

    test "BKM with decision table body receives compiled references" do
      {:ok, definitions} = DMN.parse_and_validate(read_fixture("bkm_with_decision_table.dmn"))
      [business_knowledge_model] = definitions.business_knowledge_models
      table = business_knowledge_model.encapsulated_logic.body

      assert %DecisionTable{} = table
      assert is_reference(hd(table.inputs).compiled_expression_ref)
    end

    test "BKM with literal expression body receives compiled reference" do
      {:ok, definitions} = DMN.parse_and_validate(read_fixture("bkm_with_literal_expression.dmn"))
      [business_knowledge_model] = definitions.business_knowledge_models
      literal = business_knowledge_model.encapsulated_logic.body

      assert %LiteralExpression{compiled_ref: reference} = literal
      assert is_reference(reference)
    end

    test "standalone functionDefinition on decision receives compiled body" do
      {:ok, definitions} = DMN.parse_and_validate(read_fixture("function_definition_as_value.dmn"))
      decision = Enum.find(definitions.decisions, &(&1.id == "Decision_function"))

      assert %FunctionDefinition{} = function_definition = decision.expression
      assert %LiteralExpression{compiled_ref: reference} = function_definition.body
      assert is_reference(reference)
    end

    test "standalone precompile after parse and validate" do
      {:ok, definitions} = DMN.parse(read_fixture("simple_unique.dmn"))
      {:ok, definitions} = DMN.validate(definitions)
      {:ok, definitions} = Precompiler.precompile(definitions)

      [decision] = definitions.decisions
      assert is_reference(hd(decision.expression.inputs).compiled_expression_ref)
    end

    test "dash and empty input entries are skipped during precompilation" do
      {:ok, definitions} = DMN.parse_and_validate(read_fixture("bkm_with_decision_table.dmn"))
      [business_knowledge_model] = definitions.business_knowledge_models
      table = business_knowledge_model.encapsulated_logic.body
      rules = table.rules

      dash_entry =
        rules
        |> Enum.flat_map(& &1.input_entries)
        |> Enum.find(&(&1.text == "-"))

      assert dash_entry != nil
      assert dash_entry.compiled_ref == nil
    end

    test "empty output entries are not compiled" do
      alias BfwEngine.DMN.Model.Decision
      alias BfwEngine.DMN.Model.DecisionTable
      alias BfwEngine.DMN.Model.Definitions
      alias BfwEngine.DMN.Model.Input
      alias BfwEngine.DMN.Model.Output
      alias BfwEngine.DMN.Model.Rule

      definitions = %Definitions{
        decisions: [
          %Decision{
            id: "D1",
            expression: %DecisionTable{
              id: "DT1",
              hit_policy: :unique,
              inputs: [%Input{id: "I1", input_expression: "x"}],
              outputs: [%Output{id: "O1"}],
              rules: [
                %Rule{
                  id: "R1",
                  input_entries: [%InputEntry{id: "IE1", text: "> 0"}],
                  output_entries: [%OutputEntry{id: "OE1", text: ""}]
                }
              ]
            }
          }
        ],
        raw_xml: ""
      }

      assert {:ok, precompiled} = Precompiler.precompile(definitions)
      [decision] = precompiled.decisions
      [rule] = decision.expression.rules
      [output_entry] = rule.output_entries
      assert output_entry.compiled_ref == nil
    end

    test "BKM with nil encapsulated_logic passes through" do
      alias BfwEngine.DMN.Model.BusinessKnowledgeModel
      alias BfwEngine.DMN.Model.Definitions

      definitions = %Definitions{
        business_knowledge_models: [
          %BusinessKnowledgeModel{id: "BKM_empty", encapsulated_logic: nil}
        ],
        raw_xml: ""
      }

      assert {:ok, result} = Precompiler.precompile(definitions)
      [business_knowledge_model] = result.business_knowledge_models
      assert business_knowledge_model.encapsulated_logic == nil
    end

    test "precompiles boxed context entries recursively" do
      {:ok, definitions} = DMN.parse_and_validate(read_fixture("boxed_context_basic.dmn"))
      [decision] = definitions.decisions
      context = decision.expression

      assert %BfwEngine.DMN.Model.BoxedContext{} = context

      Enum.each(context.context_entries, fn entry ->
        assert %LiteralExpression{compiled_ref: reference} = entry.expression
        assert is_reference(reference)
      end)
    end

    test "precompiles boxed list elements recursively" do
      {:ok, definitions} = DMN.parse_and_validate(read_fixture("boxed_list_basic.dmn"))
      [decision] = definitions.decisions
      list = decision.expression

      assert %BfwEngine.DMN.Model.BoxedList{} = list

      Enum.each(list.elements, fn element ->
        assert %LiteralExpression{compiled_ref: reference} = element
        assert is_reference(reference)
      end)
    end

    test "precompiles relation row cells recursively" do
      {:ok, definitions} = DMN.parse_and_validate(read_fixture("relation_basic.dmn"))
      [decision] = definitions.decisions
      relation = decision.expression

      assert %BfwEngine.DMN.Model.Relation{} = relation

      Enum.each(relation.rows, fn row ->
        Enum.each(row, fn cell ->
          assert %LiteralExpression{compiled_ref: reference} = cell
          assert is_reference(reference)
        end)
      end)
    end

    test "precompiles boxed conditional branches" do
      {:ok, definitions} = DMN.parse_and_validate(read_fixture("boxed_conditional_basic.dmn"))
      [decision] = definitions.decisions
      conditional = decision.expression

      assert %BfwEngine.DMN.Model.BoxedConditional{} = conditional
      assert %LiteralExpression{compiled_ref: if_reference} = conditional.if_expression
      assert %LiteralExpression{compiled_ref: then_reference} = conditional.then_expression
      assert %LiteralExpression{compiled_ref: else_reference} = conditional.else_expression
      assert is_reference(if_reference)
      assert is_reference(then_reference)
      assert is_reference(else_reference)
    end

    test "recursively precompiles boxed invocation bindings" do
      {:ok, definitions} = Parser.parse(read_fixture("boxed_invocation_basic.dmn"))
      {:ok, precompiled} = Precompiler.precompile(definitions)
      decision = Enum.find(precompiled.decisions, &(&1.id == "Decision_apply_tax"))
      invocation = decision.expression

      Enum.each(invocation.bindings, fn binding ->
        assert binding.expression.compiled_ref != nil,
               "Binding expression for #{binding.parameter.name} should be precompiled"
      end)
    end

    test "recursively precompiles boxed filter expressions" do
      {:ok, definitions} = Parser.parse(read_fixture("boxed_filter_basic.dmn"))
      {:ok, precompiled} = Precompiler.precompile(definitions)
      decision = Enum.find(precompiled.decisions, &(&1.id == "Decision_filter"))
      context = decision.expression

      assert %BoxedContext{} = context

      filter_entry =
        Enum.find(context.context_entries, fn entry -> is_nil(entry.variable) end)

      filter = filter_entry.expression
      assert filter.in_expression.compiled_ref != nil
      assert filter.match_expression.compiled_ref != nil
    end

    test "precompiles boxed for in_expression and return_expression" do
      {:ok, definitions} = DMN.parse_and_validate(read_fixture("boxed_iterators.dmn"))
      decision = Enum.find(definitions.decisions, &(&1.id == "Decision_for"))
      boxed_for = decision.expression

      assert %BoxedFor{} = boxed_for
      assert %LiteralExpression{compiled_ref: in_reference} = boxed_for.in_expression
      assert %LiteralExpression{compiled_ref: return_reference} = boxed_for.return_expression
      assert is_reference(in_reference)
      assert is_reference(return_reference)
    end

    test "precompiles boxed every in_expression and satisfies_expression" do
      {:ok, definitions} = DMN.parse_and_validate(read_fixture("boxed_iterators.dmn"))
      decision = Enum.find(definitions.decisions, &(&1.id == "Decision_every"))
      boxed_every = decision.expression

      assert %BoxedEvery{} = boxed_every
      assert %LiteralExpression{compiled_ref: in_reference} = boxed_every.in_expression
      assert %LiteralExpression{compiled_ref: satisfies_reference} = boxed_every.satisfies_expression
      assert is_reference(in_reference)
      assert is_reference(satisfies_reference)
    end

    test "precompiles boxed some in_expression and satisfies_expression" do
      {:ok, definitions} = DMN.parse_and_validate(read_fixture("boxed_iterators.dmn"))
      decision = Enum.find(definitions.decisions, &(&1.id == "Decision_some"))
      boxed_some = decision.expression

      assert %BoxedSome{} = boxed_some
      assert %LiteralExpression{compiled_ref: in_reference} = boxed_some.in_expression
      assert %LiteralExpression{compiled_ref: satisfies_reference} = boxed_some.satisfies_expression
      assert is_reference(in_reference)
      assert is_reference(satisfies_reference)
    end

    test "propagates import resolution failure instead of silently degrading (P2.3)" do
      alias BfwEngine.DMN.Model.Definitions
      alias BfwEngine.DMN.Model.Import

      definitions = %Definitions{
        imports: [
          %Import{
            namespace: "https://example.com/dmn/nonexistent",
            import_type: "http://www.omg.org/spec/DMN/20191111/MODEL/"
          }
        ],
        decisions: [],
        raw_xml: ""
      }

      failing_resolver = fn _namespace -> {:error, :not_found} end

      assert {:error, :import_shape_failed, metadata} =
               Precompiler.precompile(definitions, import_resolver: failing_resolver)

      assert metadata.namespace == "https://example.com/dmn/nonexistent"
      assert metadata.reason == :import_not_found
    end

    test "precompile succeeds when import resolver finds the model (P2.3 happy path)" do
      alias BfwEngine.DMN.Model.Decision
      alias BfwEngine.DMN.Model.Definitions
      alias BfwEngine.DMN.Model.Import

      imported_definitions = %Definitions{
        decisions: [
          %Decision{
            id: "Decision_helper",
            name: "Helper",
            expression: %LiteralExpression{text: "42", compiled_ref: nil}
          }
        ],
        raw_xml: ""
      }

      definitions = %Definitions{
        imports: [
          %Import{
            namespace: "https://example.com/dmn/helpers",
            import_type: "http://www.omg.org/spec/DMN/20191111/MODEL/"
          }
        ],
        decisions: [
          %Decision{
            id: "Decision_main",
            name: "Main",
            expression: %LiteralExpression{text: "1 + 1", compiled_ref: nil}
          }
        ],
        raw_xml: ""
      }

      resolver = fn "https://example.com/dmn/helpers" -> {:ok, imported_definitions} end

      assert {:ok, %Definitions{} = precompiled} =
               Precompiler.precompile(definitions, import_resolver: resolver)

      [decision] = precompiled.decisions
      assert %LiteralExpression{compiled_ref: reference} = decision.expression
      assert is_reference(reference)
    end
  end

  describe "build_rule_index/1" do
    test "builds index for columns with simple string equality literals" do
      rules = [
        %BfwEngine.DMN.Model.Rule{
          id: "r1",
          input_entries: [
            %InputEntry{id: "ie1", text: "\"approved\""},
            %InputEntry{id: "ie2", text: "\"standard\""}
          ],
          output_entries: []
        },
        %BfwEngine.DMN.Model.Rule{
          id: "r2",
          input_entries: [
            %InputEntry{id: "ie3", text: "\"rejected\""},
            %InputEntry{id: "ie4", text: "\"premium\""}
          ],
          output_entries: []
        }
      ]

      index = Precompiler.build_rule_index(rules)

      assert index != nil
      assert Map.has_key?(index, 0)
      assert Map.has_key?(index, 1)

      assert MapSet.member?(index[0].values["approved"], 0)
      assert MapSet.member?(index[0].values["rejected"], 1)
      assert MapSet.member?(index[1].values["standard"], 0)
      assert MapSet.member?(index[1].values["premium"], 1)
      assert MapSet.size(index[0].wildcards) == 0
    end

    test "includes wildcard entries in wildcards set" do
      rules = [
        %BfwEngine.DMN.Model.Rule{
          id: "r1",
          input_entries: [%InputEntry{id: "ie1", text: "\"yes\""}],
          output_entries: []
        },
        %BfwEngine.DMN.Model.Rule{
          id: "r2",
          input_entries: [%InputEntry{id: "ie2", text: "-"}],
          output_entries: []
        }
      ]

      index = Precompiler.build_rule_index(rules)

      assert index != nil
      assert MapSet.member?(index[0].values["yes"], 0)
      assert MapSet.member?(index[0].wildcards, 1)
    end

    test "returns nil for columns with non-equality expressions" do
      rules = [
        %BfwEngine.DMN.Model.Rule{
          id: "r1",
          input_entries: [%InputEntry{id: "ie1", text: "> 50"}],
          output_entries: []
        },
        %BfwEngine.DMN.Model.Rule{
          id: "r2",
          input_entries: [%InputEntry{id: "ie2", text: "< 20"}],
          output_entries: []
        }
      ]

      assert nil == Precompiler.build_rule_index(rules)
    end

    test "indexes numeric literals" do
      rules = [
        %BfwEngine.DMN.Model.Rule{
          id: "r1",
          input_entries: [%InputEntry{id: "ie1", text: "42"}],
          output_entries: []
        },
        %BfwEngine.DMN.Model.Rule{
          id: "r2",
          input_entries: [%InputEntry{id: "ie2", text: "99"}],
          output_entries: []
        }
      ]

      index = Precompiler.build_rule_index(rules)
      assert index != nil
      assert MapSet.member?(index[0].values[42], 0)
      assert MapSet.member?(index[0].values[99], 1)
    end

    test "indexes boolean literals" do
      rules = [
        %BfwEngine.DMN.Model.Rule{
          id: "r1",
          input_entries: [%InputEntry{id: "ie1", text: "true"}],
          output_entries: []
        },
        %BfwEngine.DMN.Model.Rule{
          id: "r2",
          input_entries: [%InputEntry{id: "ie2", text: "false"}],
          output_entries: []
        }
      ]

      index = Precompiler.build_rule_index(rules)
      assert index != nil
      assert MapSet.member?(index[0].values[true], 0)
      assert MapSet.member?(index[0].values[false], 1)
    end

    test "returns nil for empty rules list" do
      assert nil == Precompiler.build_rule_index([])
    end

    test "indexes only indexable columns in mixed tables" do
      rules = [
        %BfwEngine.DMN.Model.Rule{
          id: "r1",
          input_entries: [
            %InputEntry{id: "ie1", text: "\"gold\""},
            %InputEntry{id: "ie2", text: "> 100"}
          ],
          output_entries: []
        },
        %BfwEngine.DMN.Model.Rule{
          id: "r2",
          input_entries: [
            %InputEntry{id: "ie3", text: "\"silver\""},
            %InputEntry{id: "ie4", text: "< 50"}
          ],
          output_entries: []
        }
      ]

      index = Precompiler.build_rule_index(rules)
      assert index != nil
      assert Map.has_key?(index, 0)
      refute Map.has_key?(index, 1)
    end
  end

  describe "parse_equality_literal/1" do
    test "parses quoted strings" do
      assert "hello" == Precompiler.parse_equality_literal("\"hello\"")
    end

    test "parses integers" do
      assert 42 == Precompiler.parse_equality_literal("42")
    end

    test "parses floats" do
      assert 3.14 == Precompiler.parse_equality_literal("3.14")
    end

    test "parses booleans" do
      assert true == Precompiler.parse_equality_literal("true")
      assert false == Precompiler.parse_equality_literal("false")
    end

    test "returns :not_indexable for comparison operators" do
      assert :not_indexable == Precompiler.parse_equality_literal("> 50")
      assert :not_indexable == Precompiler.parse_equality_literal("< 20")
      assert :not_indexable == Precompiler.parse_equality_literal("[1..10]")
    end

    test "returns :not_indexable for FEEL function calls" do
      assert :not_indexable == Precompiler.parse_equality_literal("not(\"x\")")
      assert :not_indexable == Precompiler.parse_equality_literal("date(\"2021-01-01\")")
    end
  end
end
