defmodule EvilEngine.DMN.EvaluatorTest do
  @moduledoc false

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias EvilEngine.DMN
  alias EvilEngine.DMN.EvaluationResult
  alias EvilEngine.DMN.EvaluationTrace
  alias EvilEngine.DMN.Evaluator
  alias EvilEngine.DMN.Model.Binding
  alias EvilEngine.DMN.Model.BoxedConditional
  alias EvilEngine.DMN.Model.BoxedContext
  alias EvilEngine.DMN.Model.BoxedEvery
  alias EvilEngine.DMN.Model.BoxedFilter
  alias EvilEngine.DMN.Model.BoxedFor
  alias EvilEngine.DMN.Model.BoxedInvocation
  alias EvilEngine.DMN.Model.BoxedList
  alias EvilEngine.DMN.Model.BoxedSome
  alias EvilEngine.DMN.Model.BusinessKnowledgeModel
  alias EvilEngine.DMN.Model.ContextEntry
  alias EvilEngine.DMN.Model.Decision
  alias EvilEngine.DMN.Model.DecisionTable
  alias EvilEngine.DMN.Model.Definitions
  alias EvilEngine.DMN.Model.FunctionDefinition
  alias EvilEngine.DMN.Model.InformationItem
  alias EvilEngine.DMN.Model.Input
  alias EvilEngine.DMN.Model.InputEntry
  alias EvilEngine.DMN.Model.LiteralExpression
  alias EvilEngine.DMN.Model.Output
  alias EvilEngine.DMN.Model.OutputEntry
  alias EvilEngine.DMN.Model.Relation
  alias EvilEngine.DMN.Model.Rule
  alias EvilEngine.DMN.Parser
  alias EvilEngine.DMN.Precompiler
  alias EvilEngine.DMN.ServiceEvaluationResult

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

  describe "resolve_decision" do
    test "auto-resolves single decision when decision_id is nil" do
      definitions = parse_fixture("simple_unique.dmn")

      assert {:ok, %EvaluationResult{decision_model_id: "Decision_discount"}} =
               Evaluator.evaluate(definitions, nil, %{"age" => 25})
    end

    test "returns error for ambiguous decisions when decision_id is nil" do
      definitions = parse_fixture("all_hit_policies.dmn")

      assert {:error, :ambiguous_decision, %{message: _message}} =
               Evaluator.evaluate(definitions, nil, %{"value" => 5})
    end

    test "resolves specific decision by ID" do
      definitions = parse_fixture("all_hit_policies.dmn")
      first_decision_id = hd(definitions.decisions).id

      {:ok, result} =
        Evaluator.evaluate(definitions, first_decision_id, %{"value" => 5})

      assert %EvaluationResult{decision_model_id: ^first_decision_id} = result
    end

    test "returns error for non-existent decision_id" do
      definitions = parse_fixture("simple_unique.dmn")

      assert {:error, :decision_not_found, %{decision_id: "nonexistent_id"}} =
               Evaluator.evaluate(definitions, "nonexistent_id", %{"age" => 25})
    end

    test "returns error for empty decisions list" do
      empty_definitions = %Definitions{decisions: [], raw_xml: ""}

      assert {:error, :no_decisions, %{message: _message}} =
               Evaluator.evaluate(empty_definitions, nil, %{})
    end
  end

  describe "defensive guards" do
    test "both-expressions fixture evaluates (last expression wins in unified field)" do
      definitions = parse_fixture("invalid_both_expressions.dmn")
      assert %LiteralExpression{} = hd(definitions.decisions).expression

      assert {:error, :missing_required_input, _metadata} =
               Evaluator.evaluate(definitions, nil, %{})
    end

    test "returns error when decision has no value expression" do
      definitions = parse_fixture("invalid_no_expression.dmn")

      assert {:error, :missing_decision_logic, %{message: _message}} =
               Evaluator.evaluate(definitions, nil, %{})
    end
  end

  describe "EvaluationResult structure" do
    test "result contains all expected fields" do
      definitions = parse_fixture("simple_unique.dmn")
      {:ok, result} = Evaluator.evaluate(definitions, nil, %{"age" => 25})

      assert %EvaluationResult{
               decision_model_id: "Decision_discount",
               decision_name: "Discount Percentage",
               hit_policy: :unique,
               evaluated_at: %DateTime{},
               duration_microseconds: duration
             } = result

      assert is_integer(duration)
      assert duration >= 0
    end

    test "trace contains exactly one DecisionTrace in Phase 3" do
      definitions = parse_fixture("simple_unique.dmn")
      {:ok, result} = Evaluator.evaluate(definitions, nil, %{"age" => 25})

      assert %EvaluationTrace{decisions: [decision_trace]} = result.trace
      assert decision_trace.decision_model_id == "Decision_discount"
      assert is_list(decision_trace.inputs)
      assert is_list(decision_trace.matched_rules)
      assert is_integer(decision_trace.unmatched_rules_count)
    end
  end

  describe "precompiled expressions" do
    test "precompiled model produces same result as raw parse for UNIQUE table" do
      raw_definitions = parse_fixture("simple_unique.dmn")
      precompiled_definitions = parse_and_precompile_fixture("simple_unique.dmn")

      assert {:ok, raw_result} = Evaluator.evaluate(raw_definitions, nil, %{"age" => 25})

      assert {:ok, precompiled_result} =
               Evaluator.evaluate(precompiled_definitions, nil, %{"age" => 25})

      assert raw_result.result == precompiled_result.result
      assert raw_result.matched_rules == precompiled_result.matched_rules
    end

    test "explicit precompile after parse matches parse_and_validate path" do
      {:ok, definitions} = Parser.parse(read_fixture("simple_unique.dmn"))
      {:ok, definitions} = Precompiler.precompile(definitions)

      assert {:ok, result} = Evaluator.evaluate(definitions, nil, %{"age" => 17})
      assert result.result == %{"discount" => 10}
    end

    test "precompiled literal expression produces correct result" do
      precompiled_definitions = parse_and_precompile_fixture("literal_expression.dmn")

      assert {:ok, result} =
               Evaluator.evaluate(precompiled_definitions, nil, %{"x" => 30, "y" => 12})

      assert result.result == 42
      assert result.hit_policy == :literal
    end

    test "precompiled FIRST hit policy produces same result as raw" do
      raw_definitions = parse_fixture("with_input_data.dmn")
      precompiled_definitions = parse_and_precompile_fixture("with_input_data.dmn")

      raw_input = %{"orderAmount" => 750, "isMember" => true, "customerName" => "Alice"}

      assert {:ok, raw_result} =
               Evaluator.evaluate(raw_definitions, "Decision_discount_tier", raw_input)

      assert {:ok, precompiled_result} =
               Evaluator.evaluate(precompiled_definitions, "Decision_discount_tier", raw_input)

      assert raw_result.result == precompiled_result.result
    end
  end

  describe "DRD chaining" do
    test "linear chain evaluation produces correct result" do
      definitions = parse_and_precompile_fixture("drg_linear_chain.dmn")

      assert {:ok, result} =
               Evaluator.evaluate(definitions, "Decision_A", %{"x" => 5})

      assert result.result == 30
      assert result.decision_model_id == "Decision_A"
    end

    test "diamond evaluation produces correct result with D evaluated once" do
      definitions = parse_and_precompile_fixture("drg_diamond.dmn")

      assert {:ok, result} =
               Evaluator.evaluate(definitions, "Decision_A", %{"x" => 1})

      assert result.result == 34

      assert [%{decision_model_id: "Decision_D"} | _] = result.trace.decisions
      d_trace_count = Enum.count(result.trace.decisions, &(&1.decision_model_id == "Decision_D"))
      assert d_trace_count == 1
    end

    test "three-level chain evaluates correctly" do
      definitions = parse_and_precompile_fixture("drg_three_level.dmn")

      assert {:ok, result} =
               Evaluator.evaluate(definitions, "Decision_A", %{"x" => 0})

      assert result.result == 4
    end

    test "cycle detection returns error tuple" do
      definitions = parse_fixture("drg_cycle.dmn")

      assert {:error, :drg_cycle, %{decision_ids: _cycle_decision_ids}} =
               Evaluator.evaluate(definitions, "Decision_A", %{"x" => 1})
    end

    test "runtime evaluation rejects informationRequirement referencing unknown InputData" do
      {:ok, definitions} = DMN.parse_and_validate(read_fixture("simple_unique.dmn"))

      [decision | _] = definitions.decisions

      broken_decision = %{
        decision
        | information_requirements: [
            %EvilEngine.DMN.Model.InformationRequirement{
              id: "ir_missing_input",
              required_input_id: "InputData_nonexistent"
            }
          ]
      }

      broken_definitions = %{definitions | decisions: [broken_decision]}

      assert {:error, :missing_required_input,
              %{input_data_id: "InputData_nonexistent", input_data_name: "InputData_nonexistent"}} =
               Evaluator.evaluate(broken_definitions, nil, %{"age" => 25})
    end

    test "missing required decision returns error" do
      definitions = parse_and_precompile_fixture("drg_linear_chain.dmn")

      broken_decision =
        definitions.decisions
        |> Enum.find(&(&1.id == "Decision_A"))
        |> Map.update!(:information_requirements, fn _requirements ->
          [
            %EvilEngine.DMN.Model.InformationRequirement{
              id: "ir_broken",
              required_decision_id: "Decision_missing"
            }
          ]
        end)

      broken_definitions = %{
        definitions
        | decisions:
            Enum.map(definitions.decisions, fn decision ->
              if decision.id == "Decision_A", do: broken_decision, else: decision
            end)
      }

      assert {:error, :missing_required_decision,
              %{decision_id: "Decision_missing", required_by: "Decision_A"}} =
               Evaluator.evaluate(broken_definitions, "Decision_A", %{"x" => 5})
    end

    test "missing required input returns error" do
      definitions = parse_and_precompile_fixture("drg_linear_chain.dmn")

      assert {:error, :missing_required_input,
              %{input_data_id: "InputData_x", input_data_name: "x"}} =
               Evaluator.evaluate(definitions, "Decision_B", %{})
    end

    test "EvaluationTrace.decisions has one entry per decision in correct order" do
      definitions = parse_and_precompile_fixture("drg_three_level.dmn")

      assert {:ok, result} =
               Evaluator.evaluate(definitions, "Decision_A", %{"x" => 0})

      decision_ids = Enum.map(result.trace.decisions, & &1.decision_model_id)

      assert decision_ids == ["Decision_D", "Decision_C", "Decision_B", "Decision_A"]
      assert length(result.trace.decisions) == 4
    end

    test "single-decision without required_decision links keeps one trace entry" do
      definitions = parse_and_precompile_fixture("simple_unique.dmn")

      assert {:ok, result} =
               Evaluator.evaluate(definitions, nil, %{"age" => 25})

      assert length(result.trace.decisions) == 1
      assert hd(result.trace.decisions).decision_model_id == "Decision_discount"
    end

    test "required input binding uses InputData values from context" do
      definitions = parse_and_precompile_fixture("drg_linear_chain.dmn")

      assert {:ok, result} =
               Evaluator.evaluate(definitions, "Decision_B", %{"x" => 7})

      assert result.result == 17
    end

    test "decision variable name is used as context key for downstream binding" do
      definitions = parse_and_precompile_fixture("drg_linear_chain.dmn")

      assert {:ok, result} =
               Evaluator.evaluate(definitions, "Decision_A", %{"x" => 3})

      assert result.result == 26

      assert [b_trace, a_trace] = result.trace.decisions
      assert b_trace.decision_model_id == "Decision_B"
      assert b_trace.result == 13
      assert a_trace.decision_model_id == "Decision_A"
    end
  end

  describe "BKM invocation" do
    test "decision invokes BKM with LiteralExpression body" do
      definitions = parse_and_precompile_fixture("bkm_invocation_literal.dmn")

      assert {:ok, result} =
               Evaluator.evaluate(
                 definitions,
                 "Decision_tax",
                 %{"income" => 50_000, "taxRate" => 0.2}
               )

      assert result.result == 10_100
      assert result.decision_model_id == "Decision_tax"
    end

    test "decision invokes BKM with DecisionTable body" do
      definitions = parse_and_precompile_fixture("bkm_invocation_table.dmn")

      assert {:ok, result} =
               Evaluator.evaluate(
                 definitions,
                 "Decision_discount",
                 %{"customerAge" => 70}
               )

      assert result.result == 40
    end

    test "BKM formal parameters are bound from calling context" do
      definitions = parse_and_precompile_fixture("bkm_invocation_literal.dmn")

      assert {:ok, result} =
               Evaluator.evaluate(
                 definitions,
                 "Decision_tax",
                 %{"income" => 100_000, "taxRate" => 0.3}
               )

      assert result.result == 30_100
    end

    test "missing BKM reference returns error" do
      definitions = parse_fixture("bkm_missing_reference.dmn")

      assert {:error, :bkm_not_found, %{bkm_id: "BKM_nonexistent"}} =
               Evaluator.evaluate(definitions, "Decision_broken", %{"x" => 1})
    end

    test "BKM-to-BKM chain resolves correctly" do
      definitions = parse_and_precompile_fixture("bkm_chain.dmn")

      assert {:ok, result} =
               Evaluator.evaluate(definitions, "Decision_main", %{"n" => 3, "m" => 7})

      assert result.result == 38
    end

    test "BKM cycle returns error" do
      definitions = parse_fixture("bkm_cycle.dmn")

      assert {:error, :bkm_cycle, %{bkm_ids: cycle_bkm_ids}} =
               Evaluator.evaluate(definitions, "Decision_cycle", %{"x" => 1})

      assert "BKM_A" in cycle_bkm_ids or "BKM_B" in cycle_bkm_ids
    end

    test "BKM result available as named value in calling decision context" do
      definitions = parse_and_precompile_fixture("bkm_invocation_literal.dmn")

      assert {:ok, result} =
               Evaluator.evaluate(
                 definitions,
                 "Decision_tax",
                 %{"income" => 1_000, "taxRate" => 0.1}
               )

      assert result.result == 200
    end

    # NOTE: DMN 1.5 requires BKM formal parameters to be bound before invocation.
    # Current behavior: missing parameters bind as nil and FEEL evaluates to null
    # without surfacing an error. This test documents the gap until validation is added.
    test "BKM with missing formal parameter currently evaluates to null instead of error" do
      definitions = %Definitions{
        raw_xml: "",
        business_knowledge_models: [
          %BusinessKnowledgeModel{
            id: "BKM_multiply",
            name: "Multiply",
            variable: %InformationItem{name: "product"},
            encapsulated_logic: %FunctionDefinition{
              id: "FL_multiply",
              formal_parameters: [
                %InformationItem{name: "left", type_ref: "number"},
                %InformationItem{name: "right", type_ref: "number"}
              ],
              body: %LiteralExpression{text: "left * right", compiled_ref: nil}
            }
          }
        ],
        decisions: [
          %Decision{
            id: "Decision_product",
            name: "Product",
            knowledge_requirements: [
              %EvilEngine.DMN.Model.KnowledgeRequirement{required_knowledge_id: "BKM_multiply"}
            ],
            expression: %LiteralExpression{text: "product", compiled_ref: nil}
          }
        ]
      }

      {:ok, precompiled_definitions} = Precompiler.precompile(definitions)

      assert {:ok, result} =
               Evaluator.evaluate(precompiled_definitions, "Decision_product", %{"left" => 5})

      assert result.result == nil

      [decision_trace] = result.trace.decisions
      [bkm_trace] = decision_trace.bkm_traces
      assert bkm_trace.formal_parameters == [
               %{name: "left", bound_value: 5},
               %{name: "right", bound_value: nil}
             ]
    end

    # NOTE: BoxedInvocation should reject calls with fewer bindings than formal parameters.
    # Current behavior: unbound formal parameters are nil and the body evaluates to null.
    test "boxed invocation with too few bindings currently returns null instead of error" do
      two_parameter_bkm = %BusinessKnowledgeModel{
        id: "BKM_add",
        name: "Add",
        encapsulated_logic: %FunctionDefinition{
          id: "FL_add",
          formal_parameters: [
            %InformationItem{id: "FP_left", name: "left", type_ref: "number"},
            %InformationItem{id: "FP_right", name: "right", type_ref: "number"}
          ],
          body: %LiteralExpression{text: "left + right", compiled_ref: nil}
        }
      }

      single_binding_invocation = %BoxedInvocation{
        called_function: "Add",
        bindings: [
          %Binding{
            parameter: %InformationItem{name: "left"},
            expression: %LiteralExpression{text: "10", compiled_ref: nil}
          }
        ]
      }

      definitions = %Definitions{
        raw_xml: "",
        business_knowledge_models: [two_parameter_bkm]
      }

      {:ok, precompiled_invocation} =
        Precompiler.precompile_expression_body(single_binding_invocation, %{})

      assert {:ok, nil, bkm_traces} =
               Evaluator.evaluate_expression_body(precompiled_invocation, %{}, definitions)

      [bkm_trace] = bkm_traces
      assert bkm_trace.formal_parameters == [
               %{name: "left", bound_value: 10},
               %{name: "right", bound_value: nil}
             ]
    end

    test "BKM with multi-output table uses named output keys, not positional" do
      definitions = parse_and_precompile_fixture("bkm_multi_output_table.dmn")

      assert {:ok, result} =
               Evaluator.evaluate(definitions, "Decision_final", %{"score" => 95})

      assert is_map(result.result)
      assert result.result["grade"] == "A"
      assert result.result["passed"] == true
      refute Map.has_key?(result.result, "output_0")
      refute Map.has_key?(result.result, "output_1")
    end

    test "BKM multi-output table keys match top-level table naming convention" do
      definitions = parse_and_precompile_fixture("bkm_multi_output_table.dmn")

      assert {:ok, result} =
               Evaluator.evaluate(definitions, "Decision_final", %{"score" => 50})

      assert result.result["grade"] == "F"
      assert result.result["passed"] == false
    end
  end

  describe "to_json_map serialization" do
    test "EvaluationResult.to_json_map/1 produces JSON-safe map" do
      definitions = parse_fixture("simple_unique.dmn")
      {:ok, result} = Evaluator.evaluate(definitions, nil, %{"age" => 25})

      json_map = EvaluationResult.to_json_map(result)
      assert is_map(json_map)
      assert is_binary(json_map.hit_policy)
      assert is_binary(json_map.evaluated_at)
      assert is_integer(json_map.duration_microseconds)
      assert is_map(json_map.trace)
      assert is_list(json_map.trace.decisions)
    end
  end

  describe "cross-model import resolution" do
    alias EvilEngine.DMN.ModelCache

    setup do
      ModelCache.reset_state()
      :ok
    end

    defp deploy_helper_to_cache do
      helper_definitions = parse_and_precompile_fixture("imported_helper.dmn")
      :ok = ModelCache.put_new("version-helper", helper_definitions)
      helper_definitions
    end

    defp precompile_importing_fixture(fixture_name, helper_definitions) do
      helpers_namespace = "https://example.com/dmn/helpers"

      import_resolver = fn
        ^helpers_namespace -> {:ok, helper_definitions}
        _ -> {:error, :not_found}
      end

      {:ok, definitions} = DMN.parse_and_validate(read_fixture(fixture_name), import_resolver: import_resolver)
      definitions
    end

    test "evaluates imported decision at runtime" do
      helper_definitions = deploy_helper_to_cache()
      importing_definitions = precompile_importing_fixture("importing_model.dmn", helper_definitions)

      helpers_namespace = "https://example.com/dmn/helpers"

      import_resolver = fn
        ^helpers_namespace -> {:ok, helper_definitions}
        _ -> {:error, :not_found}
      end

      assert {:ok, %EvaluationResult{result: result}} =
               Evaluator.evaluate(
                 importing_definitions,
                 "Decision_final",
                 %{"base" => 5},
                 import_resolver: import_resolver
               )

      # base=5 → Double=5*2=10 → Final=10+10=20
      assert result == 20
    end

    test "returns import_shape_failed at precompile time when imported model is not deployed" do
      not_found_resolver = fn _ -> {:error, :not_found} end

      assert {:error, :import_shape_failed,
              %{namespace: "https://example.com/dmn/nonexistent", reason: :import_not_found}} =
               DMN.parse_and_validate(
                 read_fixture("importing_missing.dmn"),
                 import_resolver: not_found_resolver
               )
    end

    test "returns import_not_found at runtime when import resolver fails after precompile" do
      nonexistent_namespace = "https://example.com/dmn/nonexistent"

      stub_definitions = %Definitions{
        decisions: [
          %Decision{id: "Decision_stub", name: "Stub", expression: %LiteralExpression{text: "0"}}
        ],
        raw_xml: ""
      }

      precompile_resolver = fn ^nonexistent_namespace -> {:ok, stub_definitions} end
      runtime_resolver = fn _ -> {:error, :not_found} end

      {:ok, precompiled} =
        DMN.parse_and_validate(
          read_fixture("importing_missing.dmn"),
          import_resolver: precompile_resolver
        )

      assert {:error, :import_not_found, %{namespace: ^nonexistent_namespace}} =
               Evaluator.evaluate(
                 precompiled,
                 "Decision_main",
                 %{"x" => 1},
                 import_resolver: runtime_resolver
               )
    end

    test "model without imports evaluates without needing a resolver" do
      definitions = parse_fixture("simple_unique.dmn")

      assert {:ok, %EvaluationResult{}} =
               Evaluator.evaluate(definitions, nil, %{"age" => 25})
    end

    test "imported decision result is available under its variable name" do
      helper_definitions = deploy_helper_to_cache()
      importing_definitions = precompile_importing_fixture("importing_model.dmn", helper_definitions)

      helpers_namespace = "https://example.com/dmn/helpers"

      import_resolver = fn
        ^helpers_namespace -> {:ok, helper_definitions}
        _ -> {:error, :not_found}
      end

      {:ok, %EvaluationResult{result: result}} =
        Evaluator.evaluate(
          importing_definitions,
          "Decision_final",
          %{"base" => 7},
          import_resolver: import_resolver
        )

      # base=7 → Double=7*2=14 → Final=14+10=24
      assert result == 24
    end

    test "dependency resolver skips imported references in topological sort" do
      alias EvilEngine.DMN.Evaluator.DependencyResolver

      importing_definitions = parse_fixture("importing_model.dmn")

      assert {:ok, evaluation_order} =
               DependencyResolver.resolve_evaluation_order("Decision_final", importing_definitions)

      assert evaluation_order == ["Decision_final"]
    end
  end

  describe "deep import chain A→B→C (P4.3)" do
    alias EvilEngine.DMN.ModelCache

    setup do
      ModelCache.reset_state()
      :ok
    end

    test "three-level import chain evaluates correctly across models" do
      namespace_c = "https://example.com/dmn/chain-c"
      namespace_b = "https://example.com/dmn/chain-b"

      definitions_c = parse_and_precompile_fixture("import_chain_c.dmn")
      ModelCache.put_new("version-chain-c", definitions_c)

      resolver_for_b = fn
        ^namespace_c -> {:ok, definitions_c}
        _ -> {:error, :not_found}
      end

      {:ok, definitions_b} =
        DMN.parse_and_validate(read_fixture("import_chain_b.dmn"), import_resolver: resolver_for_b)

      ModelCache.put_new("version-chain-b", definitions_b)

      resolver_for_a = fn
        ^namespace_b -> {:ok, definitions_b}
        ^namespace_c -> {:ok, definitions_c}
        _ -> {:error, :not_found}
      end

      {:ok, definitions_a} =
        DMN.parse_and_validate(read_fixture("import_chain_a.dmn"), import_resolver: resolver_for_a)

      runtime_resolver = fn
        ^namespace_b -> {:ok, definitions_b}
        ^namespace_c -> {:ok, definitions_c}
        _ -> {:error, :not_found}
      end

      assert {:ok, %EvaluationResult{result: result}} =
               Evaluator.evaluate(
                 definitions_a,
                 "Decision_final_chain",
                 %{"x" => 5},
                 import_resolver: runtime_resolver
               )

      # x=5 → C: Triple=5*3=15 → B: AddTriple=15+100=115 → A: FinalChain=115+1000=1115
      assert result == 1115
    end

    test "three-level import trace contains nested import traces" do
      namespace_c = "https://example.com/dmn/chain-c"
      namespace_b = "https://example.com/dmn/chain-b"

      definitions_c = parse_and_precompile_fixture("import_chain_c.dmn")

      resolver_for_b = fn
        ^namespace_c -> {:ok, definitions_c}
        _ -> {:error, :not_found}
      end

      {:ok, definitions_b} =
        DMN.parse_and_validate(read_fixture("import_chain_b.dmn"), import_resolver: resolver_for_b)

      resolver_for_a = fn
        ^namespace_b -> {:ok, definitions_b}
        ^namespace_c -> {:ok, definitions_c}
        _ -> {:error, :not_found}
      end

      {:ok, definitions_a} =
        DMN.parse_and_validate(read_fixture("import_chain_a.dmn"), import_resolver: resolver_for_a)

      runtime_resolver = fn
        ^namespace_b -> {:ok, definitions_b}
        ^namespace_c -> {:ok, definitions_c}
        _ -> {:error, :not_found}
      end

      {:ok, %EvaluationResult{} = result} =
        Evaluator.evaluate(
          definitions_a,
          "Decision_final_chain",
          %{"x" => 2},
          import_resolver: runtime_resolver
        )

      # x=2 → C: Triple=6 → B: AddTriple=106 → A: FinalChain=1106
      assert result.result == 1106

      top_decision =
        Enum.find(result.trace.decisions, &(&1.decision_model_id == "Decision_final_chain"))

      assert top_decision != nil
      assert [_ | _] = top_decision.import_traces

      [level_1_import] = top_decision.import_traces
      assert level_1_import.namespace == namespace_b
      assert level_1_import.result == 106

      level_1_decisions =
        Enum.map(level_1_import.evaluation_trace.decisions, & &1.decision_model_id)

      assert "Decision_add_triple" in level_1_decisions

      level_1_decision =
        Enum.find(level_1_import.evaluation_trace.decisions, &(&1.decision_model_id == "Decision_add_triple"))

      assert [_ | _] = level_1_decision.import_traces

      [level_2_import] = level_1_decision.import_traces
      assert level_2_import.namespace == namespace_c
      assert level_2_import.result == 6
    end
  end

  describe "max import depth guard" do
    alias EvilEngine.DMN.ModelCache

    setup do
      ModelCache.reset_state()
      :ok
    end

    test "rejects evaluation when max_import_depth is 0 and model has imports" do
      helper_definitions = parse_and_precompile_fixture("imported_helper.dmn")

      helpers_namespace = "https://example.com/dmn/helpers"

      import_resolver = fn
        ^helpers_namespace -> {:ok, helper_definitions}
        _ -> {:error, :not_found}
      end

      {:ok, importing_definitions} =
        DMN.parse_and_validate(read_fixture("importing_model.dmn"), import_resolver: import_resolver)

      assert {:error, :max_import_depth_exceeded,
              %{depth: 1, max: 0}} =
               Evaluator.evaluate(
                 importing_definitions,
                 "Decision_final",
                 %{"base" => 5},
                 import_resolver: import_resolver,
                 max_import_depth: 0
               )
    end

    test "succeeds when max_import_depth allows the import chain" do
      helper_definitions = parse_and_precompile_fixture("imported_helper.dmn")

      helpers_namespace = "https://example.com/dmn/helpers"

      import_resolver = fn
        ^helpers_namespace -> {:ok, helper_definitions}
        _ -> {:error, :not_found}
      end

      {:ok, importing_definitions} =
        DMN.parse_and_validate(read_fixture("importing_model.dmn"), import_resolver: import_resolver)

      assert {:ok, %EvaluationResult{result: 20}} =
               Evaluator.evaluate(
                 importing_definitions,
                 "Decision_final",
                 %{"base" => 5},
                 import_resolver: import_resolver,
                 max_import_depth: 5
               )
    end

    test "model without imports works at any max_import_depth" do
      definitions = parse_and_precompile_fixture("simple_unique.dmn")

      assert {:ok, %EvaluationResult{}} =
               Evaluator.evaluate(definitions, nil, %{"age" => 25}, max_import_depth: 0)
    end

    test "imported BKM auto-invocation via knowledgeRequirement" do
      helper_definitions = parse_and_precompile_fixture("bkm_helper_model.dmn")
      helpers_namespace = "https://evilengine.dev/test/bkm-helper"

      import_resolver = fn
        ^helpers_namespace -> {:ok, helper_definitions}
        _ -> {:error, :not_found}
      end

      {:ok, consumer_definitions} =
        DMN.parse_and_validate(read_fixture("imported_bkm_consumer.dmn"), import_resolver: import_resolver)

      {:ok, %EvaluationResult{result: result}} =
        Evaluator.evaluate(
          consumer_definitions,
          "Decision_total_tax",
          %{"amount" => 15_000},
          import_resolver: import_resolver
        )

      # amount=15000 (> 10000) → Tax Rate Calculator returns 0.20
      # Total Tax = 15000 * 0.20 = 3000
      assert result == 3000
    end

    test "imported BKM with small amount uses lower rate" do
      helper_definitions = parse_and_precompile_fixture("bkm_helper_model.dmn")
      helpers_namespace = "https://evilengine.dev/test/bkm-helper"

      import_resolver = fn
        ^helpers_namespace -> {:ok, helper_definitions}
        _ -> {:error, :not_found}
      end

      {:ok, consumer_definitions} =
        DMN.parse_and_validate(read_fixture("imported_bkm_consumer.dmn"), import_resolver: import_resolver)

      {:ok, %EvaluationResult{result: result}} =
        Evaluator.evaluate(
          consumer_definitions,
          "Decision_total_tax",
          %{"amount" => 5_000},
          import_resolver: import_resolver
        )

      # amount=5000 (<=10000) → Tax Rate Calculator returns 0.10
      # Total Tax = 5000 * 0.10 = 500
      assert result == 500
    end
  end

  describe "boxed context evaluation" do
    test "evaluates context with sequential variable binding and final result" do
      definitions = parse_and_precompile_fixture("boxed_context_basic.dmn")

      assert {:ok, result} =
               Evaluator.evaluate(definitions, "Decision_context", %{})

      assert result.result == 11
    end

    test "evaluates nested context" do
      definitions = parse_and_precompile_fixture("boxed_context_nested.dmn")

      assert {:ok, result} =
               Evaluator.evaluate(definitions, "Decision_nested", %{})

      assert result.result == 16
    end

    test "evaluates boxed context where all entries have variables — returns full map" do
      context_expression = %BoxedContext{
        context_entries: [
          %ContextEntry{
            variable: %InformationItem{name: "x"},
            expression: %LiteralExpression{text: "5", compiled_ref: nil}
          },
          %ContextEntry{
            variable: %InformationItem{name: "y"},
            expression: %LiteralExpression{text: "10", compiled_ref: nil}
          }
        ]
      }

      {:ok, precompiled} =
        Precompiler.precompile_expression_body(context_expression, %{"x" => 0, "y" => 0})

      {:ok, result, _bkm_traces} =
        Evaluator.evaluate_expression_body(precompiled, %{}, %Definitions{raw_xml: ""})

      assert result == %{"x" => 5, "y" => 10}
    end
  end

  describe "boxed invocation evaluation" do
    test "evaluates boxed invocation calling a BKM" do
      {:ok, definitions} = Parser.parse(read_fixture("boxed_invocation_basic.dmn"))
      {:ok, definitions} = Precompiler.precompile(definitions)
      {:ok, result} = Evaluator.evaluate(definitions, "Decision_apply_tax", %{})
      assert result.result == 10_000 or result.result == 10_000.0
    end

    test "evaluates boxed invocation with arithmetic binding expressions" do
      tax_calculation_bkm = %BusinessKnowledgeModel{
        id: "BKM_tax",
        name: "Tax Calculation",
        encapsulated_logic: %FunctionDefinition{
          id: "FL_tax",
          formal_parameters: [
            %InformationItem{id: "FP_income", name: "income"},
            %InformationItem{id: "FP_rate", name: "rate"}
          ],
          body: %LiteralExpression{text: "income * rate", compiled_ref: nil}
        }
      }

      arithmetic_invocation = %BoxedInvocation{
        called_function: "Tax Calculation",
        bindings: [
          %Binding{
            parameter: %InformationItem{name: "income"},
            expression: %LiteralExpression{text: "1000 + 500", compiled_ref: nil}
          },
          %Binding{
            parameter: %InformationItem{name: "rate"},
            expression: %LiteralExpression{text: "0.1 + 0.1", compiled_ref: nil}
          }
        ]
      }

      definitions = %Definitions{
        raw_xml: "",
        business_knowledge_models: [tax_calculation_bkm]
      }

      {:ok, precompiled_invocation} =
        Precompiler.precompile_expression_body(arithmetic_invocation, %{})

      {:ok, result, bkm_traces} =
        Evaluator.evaluate_expression_body(precompiled_invocation, %{}, definitions)

      assert result == 300 or result == 300.0
      assert is_list(bkm_traces)
    end
  end

  describe "boxed filter evaluation" do
    test "evaluates boxed filter producing filtered list" do
      {:ok, definitions} = Parser.parse(read_fixture("boxed_filter_basic.dmn"))
      {:ok, definitions} = Precompiler.precompile(definitions)
      {:ok, result} = Evaluator.evaluate(definitions, "Decision_filter", %{})
      assert result.result == [3, 4, 5]
    end

    test "returns error when in_expression evaluates to a non-list value" do
      non_list_filter = %BoxedFilter{
        in_expression: %LiteralExpression{text: "42", compiled_ref: nil},
        match_expression: %LiteralExpression{text: "true", compiled_ref: nil}
      }

      {:ok, precompiled_filter} =
        Precompiler.precompile_expression_body(non_list_filter, %{"item" => nil})

      assert {:error, :filter_source_not_list, %{message: message}} =
               Evaluator.evaluate_expression_body(
                 precompiled_filter,
                 %{},
                 %Definitions{raw_xml: ""}
               )

      assert message == "in_expression must evaluate to a list"
    end

    test "filters relation rows by match expression over context map items" do
      people_relation = %Relation{
        columns: [
          %InformationItem{id: "col_name", name: "Name"},
          %InformationItem{id: "col_age", name: "Age"}
        ],
        rows: [
          [
            %LiteralExpression{text: "\"Alice\"", compiled_ref: nil},
            %LiteralExpression{text: "30", compiled_ref: nil}
          ],
          [
            %LiteralExpression{text: "\"Bob\"", compiled_ref: nil},
            %LiteralExpression{text: "25", compiled_ref: nil}
          ]
        ]
      }

      filter_over_relation = %BoxedFilter{
        in_expression: people_relation,
        match_expression: %LiteralExpression{text: "item.Age >= 28", compiled_ref: nil}
      }

      {:ok, precompiled_filter} =
        Precompiler.precompile_expression_body(filter_over_relation, %{"item" => nil})

      {:ok, result, _bkm_traces} =
        Evaluator.evaluate_expression_body(
          precompiled_filter,
          %{},
          %Definitions{raw_xml: ""}
        )

      assert result == [%{"Name" => "Alice", "Age" => 30}]
    end
  end

  describe "boxed list evaluation" do
    test "evaluates list of literal expressions" do
      definitions = parse_and_precompile_fixture("boxed_list_basic.dmn")

      assert {:ok, result} =
               Evaluator.evaluate(definitions, "Decision_list", %{})

      assert result.result == [10, 20, 30]
    end

    test "evaluates heterogeneous list with literal, context, and literal elements" do
      heterogeneous_list = %BoxedList{
        elements: [
          %LiteralExpression{text: "1", compiled_ref: nil},
          %BoxedContext{
            context_entries: [
              %ContextEntry{
                variable: %InformationItem{name: "label"},
                expression: %LiteralExpression{text: "\"alpha\"", compiled_ref: nil}
              },
              %ContextEntry{
                variable: %InformationItem{name: "value"},
                expression: %LiteralExpression{text: "2 + 3", compiled_ref: nil}
              }
            ]
          },
          %LiteralExpression{text: "true", compiled_ref: nil}
        ]
      }

      {:ok, precompiled_list} =
        Precompiler.precompile_expression_body(heterogeneous_list, %{"label" => "", "value" => 0})

      {:ok, result, _bkm_traces} =
        Evaluator.evaluate_expression_body(
          precompiled_list,
          %{},
          %Definitions{raw_xml: ""}
        )

      assert result == [1, %{"label" => "alpha", "value" => 5}, true]
    end

    test "evaluates heterogeneous list via decision evaluate/4" do
      heterogeneous_list = %BoxedList{
        elements: [
          %LiteralExpression{text: "7", compiled_ref: nil},
          %BoxedContext{
            context_entries: [
              %ContextEntry{
                variable: nil,
                expression: %LiteralExpression{text: "\"only-result\"", compiled_ref: nil}
              }
            ]
          }
        ]
      }

      definitions = %Definitions{
        raw_xml: "",
        decisions: [
          %Decision{
            id: "Decision_heterogeneous_list",
            name: "Heterogeneous List",
            expression: heterogeneous_list
          }
        ]
      }

      {:ok, precompiled_definitions} = Precompiler.precompile(definitions)

      assert {:ok, evaluation_result} =
               Evaluator.evaluate(precompiled_definitions, "Decision_heterogeneous_list", %{})

      assert evaluation_result.result == [7, "only-result"]
    end
  end

  describe "relation evaluation" do
    test "evaluates relation as list of context maps" do
      definitions = parse_and_precompile_fixture("relation_basic.dmn")

      assert {:ok, result} =
               Evaluator.evaluate(definitions, "Decision_relation", %{})

      assert result.result == [
               %{"Name" => "Alice", "Age" => 30},
               %{"Name" => "Bob", "Age" => 25}
             ]
    end
  end

  describe "boxed conditional evaluation" do
    test "evaluates conditional — true branch" do
      definitions = parse_and_precompile_fixture("boxed_conditional_basic.dmn")

      assert {:ok, result} =
               Evaluator.evaluate(definitions, "Decision_conditional", %{"score" => 150})

      assert result.result == "high"
    end

    test "evaluates conditional — false branch" do
      definitions = parse_and_precompile_fixture("boxed_conditional_basic.dmn")

      assert {:ok, result} =
               Evaluator.evaluate(definitions, "Decision_conditional", %{"score" => 50})

      assert result.result == "low"
    end

    test "evaluates nested conditional in else branch when outer is false and inner is true" do
      inner_conditional = %BoxedConditional{
        if_expression: %LiteralExpression{text: "inner_condition", compiled_ref: nil},
        then_expression: %LiteralExpression{text: "\"inner-then\"", compiled_ref: nil},
        else_expression: %LiteralExpression{text: "\"inner-else\"", compiled_ref: nil}
      }

      nested_conditional = %BoxedConditional{
        if_expression: %LiteralExpression{text: "outer_condition", compiled_ref: nil},
        then_expression: %LiteralExpression{text: "\"outer-then\"", compiled_ref: nil},
        else_expression: inner_conditional
      }

      input_context = %{"outer_condition" => false, "inner_condition" => true}

      {:ok, precompiled_conditional} =
        Precompiler.precompile_expression_body(nested_conditional, input_context)

      {:ok, result, _bkm_traces} =
        Evaluator.evaluate_expression_body(
          precompiled_conditional,
          input_context,
          %Definitions{raw_xml: ""}
        )

      assert result == "inner-then"
    end
  end

  describe "boxed iterator evaluation" do
    test "for/return maps over list" do
      definitions = parse_and_precompile_fixture("boxed_iterators.dmn")

      assert {:ok, result} =
               Evaluator.evaluate(definitions, "Decision_for", %{"numbers" => [1, 2, 3]})

      assert result.result == [2, 4, 6]
    end

    test "every with all true returns true" do
      definitions = parse_and_precompile_fixture("boxed_iterators.dmn")

      assert {:ok, result} =
               Evaluator.evaluate(definitions, "Decision_every", %{"numbers" => [1, 2, 3]})

      assert result.result == true
    end

    test "every with one false returns false" do
      definitions = parse_and_precompile_fixture("boxed_iterators.dmn")

      assert {:ok, result} =
               Evaluator.evaluate(definitions, "Decision_every", %{"numbers" => [1, -2, 3]})

      assert result.result == false
    end

    test "some with one match returns true" do
      definitions = parse_and_precompile_fixture("boxed_iterators.dmn")

      assert {:ok, result} =
               Evaluator.evaluate(definitions, "Decision_some", %{"numbers" => [1, 2, 15]})

      assert result.result == true
    end

    test "some with no matches returns false" do
      definitions = parse_and_precompile_fixture("boxed_iterators.dmn")

      assert {:ok, result} =
               Evaluator.evaluate(definitions, "Decision_some", %{"numbers" => [1, 2, 3]})

      assert result.result == false
    end

    test "evaluates boxed for with empty list — returns empty list" do
      empty_for = %BoxedFor{
        iterator_variable: "x",
        in_expression: %LiteralExpression{text: "[]", compiled_ref: nil},
        return_expression: %LiteralExpression{text: "x * 2", compiled_ref: nil}
      }

      {:ok, precompiled} = Precompiler.precompile_expression_body(empty_for, %{"x" => 0})

      {:ok, result, _bkm_traces} =
        Evaluator.evaluate_expression_body(precompiled, %{}, %Definitions{raw_xml: ""})

      assert result == []
    end

    test "evaluates boxed every with empty list — returns true" do
      empty_every = %BoxedEvery{
        iterator_variable: "x",
        in_expression: %LiteralExpression{text: "[]", compiled_ref: nil},
        satisfies_expression: %LiteralExpression{text: "x > 0", compiled_ref: nil}
      }

      {:ok, precompiled} = Precompiler.precompile_expression_body(empty_every, %{"x" => 0})

      {:ok, result, _bkm_traces} =
        Evaluator.evaluate_expression_body(precompiled, %{}, %Definitions{raw_xml: ""})

      assert result == true
    end

    test "evaluates boxed some with empty list — returns false" do
      empty_some = %BoxedSome{
        iterator_variable: "x",
        in_expression: %LiteralExpression{text: "[]", compiled_ref: nil},
        satisfies_expression: %LiteralExpression{text: "x > 0", compiled_ref: nil}
      }

      {:ok, precompiled} = Precompiler.precompile_expression_body(empty_some, %{"x" => 0})

      {:ok, result, _bkm_traces} =
        Evaluator.evaluate_expression_body(precompiled, %{}, %Definitions{raw_xml: ""})

      assert result == false
    end
  end

  describe "function definition as expression value" do
    test "decision with FunctionDefinition expression returns {:function, function_definition} tuple" do
      definitions = parse_and_precompile_fixture("function_definition_as_value.dmn")

      assert {:ok, result} =
               Evaluator.evaluate(definitions, "Decision_function", %{})

      assert {:function, %FunctionDefinition{id: "FD_increment"} = function_definition} =
               result.result

      assert function_definition.type == :feel
      assert [%InformationItem{name: "value"}] = function_definition.formal_parameters
      assert %LiteralExpression{text: "value + 1"} = function_definition.body
    end

    test "context entry containing FunctionDefinition binds function to variable name" do
      definitions = parse_and_precompile_fixture("function_definition_as_value.dmn")

      assert {:ok, result} =
               Evaluator.evaluate(definitions, "Decision_context_function", %{})

      assert {:function, %FunctionDefinition{id: "FD_context_increment"}} =
               result.result["increment"]
    end
  end

  describe "nested boxed expressions across types" do
    test "evaluates Context containing Invocation of BKM with List body" do
      definitions = parse_and_precompile_fixture("nested_boxed_multi_type.dmn")

      assert {:ok, result} =
               Evaluator.evaluate(definitions, "Decision_nested_multi", %{})

      assert result.result == [10, 20, 30]
    end
  end

  describe "evaluate_service/4 — decision service" do
    test "evaluates basic decision service and returns only output decisions" do
      definitions = parse_and_precompile_fixture("decision_service_basic.dmn")
      input = %{"Age" => 30, "Income" => 50_000}

      assert {:ok, %ServiceEvaluationResult{} = result} =
               Evaluator.evaluate_service(definitions, "DS_eligibility", input)

      assert result.service_id == "DS_eligibility"
      assert result.service_name == "Eligibility Service"
      assert is_map(result.outputs)
      assert Map.has_key?(result.outputs, "Eligibility")
      assert result.outputs["Eligibility"] == "approved"
      assert result.duration_microseconds > 0
    end

    test "encapsulated decisions are not in output results" do
      definitions = parse_and_precompile_fixture("decision_service_basic.dmn")
      input = %{"Age" => 30, "Income" => 50_000}

      {:ok, result} = Evaluator.evaluate_service(definitions, "DS_eligibility", input)

      refute Map.has_key?(result.outputs, "Risk Score")
      assert map_size(result.outputs) == 1
    end

    test "nested decision service with multiple encapsulated decisions" do
      definitions = parse_and_precompile_fixture("decision_service_nested.dmn")
      input = %{"Amount" => 15_000, "Category" => "premium"}

      {:ok, result} = Evaluator.evaluate_service(definitions, "DS_fee_calculation", input)

      assert Map.has_key?(result.outputs, "Fee")
      assert is_number(result.outputs["Fee"])
      assert result.outputs["Fee"] == 15_000 * 0.05 * 0.9
    end

    test "decision service with input decisions" do
      definitions = parse_and_precompile_fixture("decision_service_nested.dmn")
      input = %{"Amount" => 5_000, "Category" => "standard"}

      {:ok, result} = Evaluator.evaluate_service(definitions, "DS_with_input_decisions", input)

      assert Map.has_key?(result.outputs, "Fee")
      assert result.outputs["Fee"] == 5_000 * 0.10
    end

    test "returns error for non-existent service" do
      definitions = parse_and_precompile_fixture("decision_service_basic.dmn")

      assert {:error, :service_not_found, %{service_id: "DS_nonexistent"}} =
               Evaluator.evaluate_service(definitions, "DS_nonexistent", %{})
    end

    test "trace includes all evaluated decisions" do
      definitions = parse_and_precompile_fixture("decision_service_basic.dmn")
      input = %{"Age" => 60, "Income" => 20_000}

      {:ok, result} = Evaluator.evaluate_service(definitions, "DS_eligibility", input)

      assert length(result.trace.decisions) >= 2
      decision_ids = Enum.map(result.trace.decisions, & &1.decision_model_id)
      assert "Decision_risk" in decision_ids
      assert "Decision_eligibility" in decision_ids
    end

    test "service returns denied when conditions not met" do
      definitions = parse_and_precompile_fixture("decision_service_basic.dmn")
      input = %{"Age" => 60, "Income" => 20_000}

      {:ok, result} = Evaluator.evaluate_service(definitions, "DS_eligibility", input)

      assert result.outputs["Eligibility"] == "denied"
    end

    test "to_json_map serializes service result" do
      definitions = parse_and_precompile_fixture("decision_service_basic.dmn")
      input = %{"Age" => 30, "Income" => 50_000}

      {:ok, result} = Evaluator.evaluate_service(definitions, "DS_eligibility", input)
      json_map = ServiceEvaluationResult.to_json_map(result)

      assert json_map.service_id == "DS_eligibility"
      assert json_map.service_name == "Eligibility Service"
      assert is_map(json_map.outputs)
      assert is_binary(json_map.evaluated_at)
      assert is_map(json_map.trace)
    end

    test "returns error when required service input data is missing" do
      definitions = parse_and_precompile_fixture("decision_service_basic.dmn")

      assert {:error, :missing_service_input,
              %{service_id: "DS_eligibility", missing_inputs: missing}} =
               Evaluator.evaluate_service(definitions, "DS_eligibility", %{"Age" => 30})

      assert "Income" in missing
    end

    test "returns error when all service input data is missing" do
      definitions = parse_and_precompile_fixture("decision_service_basic.dmn")

      assert {:error, :missing_service_input,
              %{service_id: "DS_eligibility", missing_inputs: missing}} =
               Evaluator.evaluate_service(definitions, "DS_eligibility", %{})

      assert "Age" in missing
      assert "Income" in missing
    end

    test "accepts extra inputs beyond service boundary (no stripping)" do
      definitions = parse_and_precompile_fixture("decision_service_basic.dmn")
      input = %{"Age" => 30, "Income" => 50_000, "ExtraField" => "ignored"}

      {:ok, result} = Evaluator.evaluate_service(definitions, "DS_eligibility", input)
      assert result.outputs["Eligibility"] == "approved"
    end

    test "rejects nil values for required service inputs" do
      definitions = parse_and_precompile_fixture("decision_service_basic.dmn")
      input = %{"Age" => 30, "Income" => nil}

      assert {:error, :missing_service_input, %{missing_inputs: missing}} =
               Evaluator.evaluate_service(definitions, "DS_eligibility", input)

      assert "Income" in missing
    end
  end

  describe "negated unary test evaluation (P4.10)" do
    # NOTE: The dsntk FEEL NIF currently returns nil for `not()` in unary test
    # context. These tests document the current behavior: negated tests are
    # treated as no-match with a logged warning (P3.1). When the NIF is updated
    # to support negated unary tests, these tests will need to be revised to
    # assert correct matching semantics instead.

    test "not(> 50) does not crash and falls through to non-negated rule" do
      definitions = parse_and_precompile_fixture("negated_unary_tests.dmn")

      log =
        capture_log([level: :warning], fn ->
          {:ok, result} = Evaluator.evaluate(definitions, "Decision_negated", %{"value" => 30})
          assert result.result == nil or result.result == %{"result" => "at_most_50"}
        end)

      assert log =~ "DMN unary test evaluation failed"
    end

    test "non-negated rule still matches when value > 50" do
      definitions = parse_and_precompile_fixture("negated_unary_tests.dmn")

      {:ok, result} = Evaluator.evaluate(definitions, "Decision_negated", %{"value" => 60})
      assert result.result == %{"result" => "above_50"}
    end

    test "not([1..10]) does not crash and is handled gracefully" do
      definitions = parse_and_precompile_fixture("negated_unary_tests.dmn")

      log =
        capture_log([level: :warning], fn ->
          {:ok, result} =
            Evaluator.evaluate(definitions, "Decision_negated_range", %{"value" => 15})

          assert result.result == nil or result.result == %{"result" => "outside_range"}
        end)

      assert log =~ "DMN unary test evaluation failed"
    end

    test "non-negated range rule [1..10] correctly matches inside values" do
      definitions = parse_and_precompile_fixture("negated_unary_tests.dmn")

      {:ok, result} =
        Evaluator.evaluate(definitions, "Decision_negated_range", %{"value" => 5})

      assert result.result == %{"result" => "inside_range"}
    end
  end

  describe "date/time typed InputData evaluation (P4.6)" do
    test "TypeResolver coerces date string to FEEL date tuple" do
      alias EvilEngine.DMN.TypeResolver

      definitions = %Definitions{item_definitions: [], raw_xml: ""}

      assert {:ok, {:feel_date, date_string}} =
               TypeResolver.coerce_value("1990-05-15", "date", definitions)

      assert date_string =~ "1990-05-15"
    end

    test "TypeResolver coerces dateTime string to FEEL dateTime tuple" do
      alias EvilEngine.DMN.TypeResolver

      definitions = %Definitions{item_definitions: [], raw_xml: ""}

      assert {:ok, {:feel_datetime, datetime_string}} =
               TypeResolver.coerce_value("2025-03-20T14:30:00", "dateTime", definitions)

      assert datetime_string =~ "2025-03-20"
    end

    test "TypeResolver coerces time string to FEEL time tuple" do
      alias EvilEngine.DMN.TypeResolver

      definitions = %Definitions{item_definitions: [], raw_xml: ""}

      assert {:ok, {:feel_time, time_string}} =
               TypeResolver.coerce_value("14:30:00", "time", definitions)

      assert time_string =~ "14:30"
    end

    test "coerce_input_context processes date-typed InputData from fixture" do
      alias EvilEngine.DMN.TypeResolver

      definitions = parse_fixture("date_time_input.dmn")

      {:ok, coerced} =
        TypeResolver.coerce_input_context(definitions, %{"birthDate" => "1990-05-15"})

      assert {:feel_date, _} = coerced["birthDate"]
    end

    test "coerce_input_context_with_trace records date coercion" do
      alias EvilEngine.DMN.TypeResolver

      definitions = parse_fixture("date_time_input.dmn")

      {:ok, _coerced, traces} =
        TypeResolver.coerce_input_context_with_trace(definitions, %{"birthDate" => "1990-05-15"})

      assert [_ | _] = traces
      date_trace = Enum.find(traces, &(&1.input_name == "birthDate"))
      assert date_trace != nil
      assert date_trace.coerced == true
      assert date_trace.target_type == "DateType"
      assert date_trace.original_value == "1990-05-15"
      assert {:feel_date, _} = date_trace.coerced_value
    end

    test "invalid date string returns coercion error" do
      alias EvilEngine.DMN.TypeResolver

      definitions = %Definitions{item_definitions: [], raw_xml: ""}

      assert {:error, :type_coercion_failed, _} =
               TypeResolver.coerce_value("not-a-date", "date", definitions)
    end
  end

  describe "silent failure observability (P3)" do
    defp build_single_rule_table_definitions(input_entry_text, output_entry_text) do
      %Definitions{
        raw_xml: "",
        decisions: [
          %Decision{
            id: "Decision_test",
            name: "Test Decision",
            expression: %DecisionTable{
              id: "DT_test",
              hit_policy: :first,
              inputs: [
                %Input{id: "Input_1", label: "value", input_expression: "value"}
              ],
              outputs: [
                %Output{id: "Output_1", name: "result", label: "result"}
              ],
              rules: [
                %Rule{
                  id: "Rule_1",
                  input_entries: [
                    %InputEntry{id: "IE_1", text: input_entry_text}
                  ],
                  output_entries: [
                    %OutputEntry{id: "OE_1", text: output_entry_text}
                  ]
                }
              ]
            }
          }
        ]
      }
    end

    test "P3.1: logs warning when unary test evaluation fails (non-precompiled path)" do
      definitions = build_single_rule_table_definitions("this is not valid FEEL at all !!!", "42")

      log =
        capture_log([level: :warning], fn ->
          {:ok, result} = Evaluator.evaluate(definitions, "Decision_test", %{"value" => 10})

          assert result.result == nil
          assert result.matched_rules == []
        end)

      assert log =~ "DMN unary test evaluation failed"
      assert log =~ "this is not valid FEEL at all !!!"
    end

    test "P3.1: unary test error preserves no-match semantics — rule does not match" do
      definitions = build_single_rule_table_definitions("completely broken FEEL {{{", "42")

      capture_log([level: :warning], fn ->
        {:ok, result} = Evaluator.evaluate(definitions, "Decision_test", %{"value" => 10})

        assert result.matched_rules == []
        assert result.result == nil
      end)
    end

    test "P3.1: valid unary tests do not produce log warnings" do
      definitions = build_single_rule_table_definitions("> 5", "42")

      log =
        capture_log([level: :warning], fn ->
          {:ok, result} = Evaluator.evaluate(definitions, "Decision_test", %{"value" => 10})
          assert result.result == %{"result" => 42}
        end)

      refute log =~ "DMN unary test evaluation failed"
    end

    test "P3.2: logs warning when output entry evaluation fails and falls back to raw text" do
      definitions =
        build_single_rule_table_definitions("-", "this is not valid FEEL output {{{")

      log =
        capture_log([level: :warning], fn ->
          {:ok, result} = Evaluator.evaluate(definitions, "Decision_test", %{"value" => 10})

          assert result.result == %{"result" => "this is not valid FEEL output {{{"}
        end)

      assert log =~ "DMN output entry evaluation failed"
      assert log =~ "falling back to raw text"
      assert log =~ "this is not valid FEEL output {{{"
    end

    test "P3.2: valid output entries do not produce log warnings" do
      definitions = build_single_rule_table_definitions("-", "42")

      log =
        capture_log([level: :warning], fn ->
          {:ok, result} = Evaluator.evaluate(definitions, "Decision_test", %{"value" => 10})
          assert result.result == %{"result" => 42}
        end)

      refute log =~ "DMN output entry evaluation failed"
    end

    test "P3.2: output entry fallback preserves raw text string as result value" do
      definitions =
        build_single_rule_table_definitions("-", "{{{{ totally broken syntax")

      capture_log([level: :warning], fn ->
        {:ok, result} = Evaluator.evaluate(definitions, "Decision_test", %{"value" => 1})

        assert result.result == %{"result" => "{{{{ totally broken syntax"}
      end)
    end
  end

  # =========================================================================
  # inputValues constraints (P6.4)
  # =========================================================================

  describe "inputValues constraints" do
    test "accepts value within allowed enumeration" do
      definitions = parse_fixture("input_values_constraint.dmn")

      {:ok, result} =
        Evaluator.evaluate(definitions, "Decision_constrained", %{"grade" => "A"})

      assert result.result == %{"pass" => "excellent"}
    end

    test "rejects value outside allowed enumeration" do
      definitions = parse_fixture("input_values_constraint.dmn")

      assert {:error, :input_value_violation, %{input_id: "input_grade", value: "Z", allowed_values: allowed}} =
               Evaluator.evaluate(definitions, "Decision_constrained", %{"grade" => "Z"})

      assert allowed =~ "\"A\""
    end

    test "tables without inputValues accept any value" do
      definitions = parse_fixture("input_values_constraint.dmn")

      {:ok, result} =
        Evaluator.evaluate(definitions, "Decision_unconstrained", %{"grade" => "anything"})

      assert result.result == nil
    end

    test "accepts value within allowed range" do
      definitions = parse_fixture("input_values_constraint.dmn")

      {:ok, result} =
        Evaluator.evaluate(definitions, "Decision_range_constrained", %{"score" => 85})

      assert result.result == %{"level" => "pass"}
    end

    test "rejects value outside allowed range" do
      definitions = parse_fixture("input_values_constraint.dmn")

      assert {:error, :input_value_violation, %{input_id: "input_score", value: 150}} =
               Evaluator.evaluate(definitions, "Decision_range_constrained", %{"score" => 150})
    end

    test "outputValues on output columns is used for PRIORITY ordering, not runtime rejection" do
      definitions = parse_fixture("priority_hit_policy.dmn")
      [decision] = definitions.decisions
      [output] = decision.expression.outputs
      assert output.output_values =~ "critical"

      {:ok, result} = Evaluator.evaluate(definitions, nil, %{"score" => 95})
      assert result.result == %{"level" => "critical"}

      {:ok, multi_match_result} = Evaluator.evaluate(definitions, nil, %{"score" => 75})
      assert multi_match_result.result == %{"level" => "high"}
    end
  end

  describe "rule index correctness" do
    defp strip_rule_index(%Definitions{} = definitions) do
      updated_decisions =
        Enum.map(definitions.decisions, fn decision ->
          case decision.expression do
            %DecisionTable{} = table ->
              %{decision | expression: %{table | rule_index: nil}}

            other ->
              %{decision | expression: other}
          end
        end)

      %{definitions | decisions: updated_decisions}
    end

    defp evaluate_with_and_without_index(definitions, decision_id, input) do
      {:ok, indexed_result} = Evaluator.evaluate(definitions, decision_id, input)

      stripped = strip_rule_index(definitions)
      {:ok, unindexed_result} = Evaluator.evaluate(stripped, decision_id, input)

      {indexed_result, unindexed_result}
    end

    defp assert_same_result(definitions, decision_id, input) do
      {indexed, unindexed} = evaluate_with_and_without_index(definitions, decision_id, input)

      assert indexed.result == unindexed.result,
             "Index changed result for #{decision_id} with input #{inspect(input)}.\n" <>
               "  Indexed:   #{inspect(indexed.result)}\n" <>
               "  Unindexed: #{inspect(unindexed.result)}"

      indexed.result
    end

    defp assert_no_match(definitions, decision_id, input) do
      {indexed, unindexed} = evaluate_with_and_without_index(definitions, decision_id, input)

      assert indexed.result == unindexed.result
      assert indexed.result == nil
    end

    setup do
      definitions = parse_and_precompile_fixture("index_correctness.dmn")
      %{definitions: definitions}
    end

    test "fully indexed table: matching input produces identical result",
         %{definitions: definitions} do
      result = assert_same_result(definitions, "Decision_fully_indexed", %{
        "tier" => "gold", "region" => "EU"
      })

      assert result == %{"result" => 100}
    end

    test "fully indexed table: all rules produce identical results",
         %{definitions: definitions} do
      assert %{"result" => 100} ==
               assert_same_result(definitions, "Decision_fully_indexed", %{
                 "tier" => "gold", "region" => "EU"
               })

      assert %{"result" => 200} ==
               assert_same_result(definitions, "Decision_fully_indexed", %{
                 "tier" => "gold", "region" => "US"
               })

      assert %{"result" => 50} ==
               assert_same_result(definitions, "Decision_fully_indexed", %{
                 "tier" => "silver", "region" => "EU"
               })

      assert %{"result" => 75} ==
               assert_same_result(definitions, "Decision_fully_indexed", %{
                 "tier" => "silver", "region" => "US"
               })

      assert %{"result" => 10} ==
               assert_same_result(definitions, "Decision_fully_indexed", %{
                 "tier" => "bronze", "region" => "APAC"
               })
    end

    test "fully indexed table: non-matching input returns nil identically",
         %{definitions: definitions} do
      assert_no_match(definitions, "Decision_fully_indexed", %{
        "tier" => "gold", "region" => "APAC"
      })

      assert_no_match(definitions, "Decision_fully_indexed", %{
        "tier" => "platinum", "region" => "EU"
      })

      assert_no_match(definitions, "Decision_fully_indexed", %{
        "tier" => "unknown", "region" => "unknown"
      })
    end

    test "wildcard table: specific match beats wildcard via FIRST policy",
         %{definitions: definitions} do
      result = assert_same_result(definitions, "Decision_with_wildcards", %{
        "tier" => "gold", "region" => "EU"
      })

      assert result == %{"result" => 100}
    end

    test "wildcard table: partial wildcard match works correctly",
         %{definitions: definitions} do
      result = assert_same_result(definitions, "Decision_with_wildcards", %{
        "tier" => "gold", "region" => "US"
      })

      assert result == %{"result" => 80}

      result = assert_same_result(definitions, "Decision_with_wildcards", %{
        "tier" => "silver", "region" => "EU"
      })

      assert result == %{"result" => 30}
    end

    test "wildcard table: double-wildcard fallback works correctly",
         %{definitions: definitions} do
      result = assert_same_result(definitions, "Decision_with_wildcards", %{
        "tier" => "bronze", "region" => "APAC"
      })

      assert result == %{"result" => 10}
    end

    test "mixed columns: indexed column filters, FEEL column evaluates",
         %{definitions: definitions} do
      assert %{"result" => 500} ==
               assert_same_result(definitions, "Decision_mixed_columns", %{
                 "tier" => "gold", "score" => 90
               })

      assert %{"result" => 200} ==
               assert_same_result(definitions, "Decision_mixed_columns", %{
                 "tier" => "gold", "score" => 50
               })

      assert %{"result" => 100} ==
               assert_same_result(definitions, "Decision_mixed_columns", %{
                 "tier" => "silver", "score" => 80
               })

      assert %{"result" => 25} ==
               assert_same_result(definitions, "Decision_mixed_columns", %{
                 "tier" => "silver", "score" => 30
               })

      assert %{"result" => 5} ==
               assert_same_result(definitions, "Decision_mixed_columns", %{
                 "tier" => "bronze", "score" => 999
               })
    end

    test "mixed columns: non-matching indexed column correctly excludes",
         %{definitions: definitions} do
      assert_no_match(definitions, "Decision_mixed_columns", %{
        "tier" => "platinum", "score" => 90
      })
    end

    test "numeric index: integer equality works correctly",
         %{definitions: definitions} do
      assert %{"result" => "alpha"} ==
               assert_same_result(definitions, "Decision_numeric_index", %{"code" => 1})

      assert %{"result" => "beta"} ==
               assert_same_result(definitions, "Decision_numeric_index", %{"code" => 2})

      assert %{"result" => "gamma"} ==
               assert_same_result(definitions, "Decision_numeric_index", %{"code" => 3})

      assert %{"result" => "special"} ==
               assert_same_result(definitions, "Decision_numeric_index", %{"code" => 99})
    end

    test "numeric index: non-matching integer returns nil identically",
         %{definitions: definitions} do
      assert_no_match(definitions, "Decision_numeric_index", %{"code" => 42})
      assert_no_match(definitions, "Decision_numeric_index", %{"code" => 0})
    end

    test "existing load fixture: indexed evaluation matches unindexed",
         %{definitions: _definitions} do
      load_xml =
        [__DIR__, "..", "..", "..", "..", "..", "test", "fixtures", "dmns", "load_10_rules.dmn"]
        |> Path.join()
        |> Path.expand()
        |> File.read!()

      {:ok, load_definitions} = DMN.parse_and_validate(load_xml)
      table = hd(load_definitions.decisions).expression

      assert table.rule_index != nil,
             "load_10_rules.dmn should have a rule index"

      assert %{"discount" => 0.01} ==
               assert_same_result(load_definitions, nil, %{
                 "age" => 18, "status" => "standard"
               })

      assert %{"discount" => 0.05} ==
               assert_same_result(load_definitions, nil, %{
                 "age" => 50, "status" => "silver"
               })

      assert %{"discount" => 0.10} ==
               assert_same_result(load_definitions, nil, %{
                 "age" => 90, "status" => "trial"
               })

      assert_no_match(load_definitions, nil, %{
        "age" => 18, "status" => "premium"
      })

      assert_no_match(load_definitions, nil, %{
        "age" => 999, "status" => "standard"
      })
    end
  end
end
