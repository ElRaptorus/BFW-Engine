defmodule BfwEngine.DMN.ValidatorTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias BfwEngine.DMN.Model.AuthorityRequirement
  alias BfwEngine.DMN.Model.Binding
  alias BfwEngine.DMN.Model.BoxedConditional
  alias BfwEngine.DMN.Model.BoxedContext
  alias BfwEngine.DMN.Model.BoxedEvery
  alias BfwEngine.DMN.Model.BoxedFilter
  alias BfwEngine.DMN.Model.BoxedFor
  alias BfwEngine.DMN.Model.BoxedInvocation
  alias BfwEngine.DMN.Model.BoxedSome
  alias BfwEngine.DMN.Model.BusinessKnowledgeModel
  alias BfwEngine.DMN.Model.ContextEntry
  alias BfwEngine.DMN.Model.Decision
  alias BfwEngine.DMN.Model.DecisionService
  alias BfwEngine.DMN.Model.Definitions
  alias BfwEngine.DMN.Model.FunctionDefinition
  alias BfwEngine.DMN.Model.Import
  alias BfwEngine.DMN.Model.InformationItem
  alias BfwEngine.DMN.Model.InformationRequirement
  alias BfwEngine.DMN.Model.InputData
  alias BfwEngine.DMN.Model.ItemDefinition
  alias BfwEngine.DMN.Model.KnowledgeRequirement
  alias BfwEngine.DMN.Model.KnowledgeSource
  alias BfwEngine.DMN.Model.LiteralExpression
  alias BfwEngine.DMN.Model.Relation
  alias BfwEngine.DMN.Parser
  alias BfwEngine.DMN.Validator

  @fixtures_dir Path.join([__DIR__, "..", "..", "fixtures", "dmns"])

  defp read_fixture(name), do: File.read!(Path.join(@fixtures_dir, name))

  defp parse_fixture(name) do
    {:ok, definitions} = Parser.parse(read_fixture(name))
    definitions
  end

  @inline_definitions_header ~s(<?xml version="1.0" encoding="UTF-8"?>
<definitions xmlns="https://www.omg.org/spec/DMN/20191111/MODEL/"
             id="Definitions_inline"
             name="Inline Validator Test"
             namespace="https://test.example.com/dmn/inline">)

  @inline_definitions_footer "</definitions>"

  defp inline_dmn(body), do: @inline_definitions_header <> body <> @inline_definitions_footer

  defp parse_inline_dmn(body) do
    {:ok, definitions} = Parser.parse(inline_dmn(body))
    definitions
  end

  defp minimal_decision(id, opts \\ []) do
    %Decision{
      id: id,
      name: Keyword.get(opts, :name, id),
      expression: %LiteralExpression{id: "le_#{id}", text: "1"},
      knowledge_requirements: Keyword.get(opts, :knowledge_requirements, []),
      information_requirements: Keyword.get(opts, :information_requirements, []),
      authority_requirements: Keyword.get(opts, :authority_requirements, [])
    }
  end

  defp minimal_bkm(id, opts \\ []) do
    %BusinessKnowledgeModel{
      id: id,
      name: Keyword.get(opts, :name, id),
      encapsulated_logic:
        Keyword.get(opts, :encapsulated_logic, %FunctionDefinition{
          id: "fn_#{id}",
          type: :feel,
          body: %LiteralExpression{id: "le_#{id}", text: "1"}
        }),
      knowledge_requirements: Keyword.get(opts, :knowledge_requirements, []),
      authority_requirements: Keyword.get(opts, :authority_requirements, []),
      variable: Keyword.get(opts, :variable)
    }
  end

  defp minimal_definitions(opts) do
    %Definitions{
      raw_xml: "",
      decisions: Keyword.get(opts, :decisions, [minimal_decision("D1")]),
      business_knowledge_models: Keyword.get(opts, :business_knowledge_models, []),
      knowledge_sources: Keyword.get(opts, :knowledge_sources, []),
      decision_services: Keyword.get(opts, :decision_services, []),
      input_data: Keyword.get(opts, :input_data, []),
      item_definitions: Keyword.get(opts, :item_definitions, []),
      imports: Keyword.get(opts, :imports, [])
    }
  end

  describe "validate/1 — valid models" do
    test "valid simple UNIQUE table passes validation" do
      definitions = parse_fixture("simple_unique.dmn")
      assert {:ok, ^definitions} = Validator.validate(definitions)
    end

    test "valid literal expression passes validation" do
      definitions = parse_fixture("literal_expression.dmn")
      assert {:ok, ^definitions} = Validator.validate(definitions)
    end

    test "valid mixed model (one table + one literal) passes validation" do
      definitions = parse_fixture("mixed_decisions.dmn")
      assert {:ok, ^definitions} = Validator.validate(definitions)
    end

    test "valid COLLECT with SUM aggregation passes" do
      definitions = parse_fixture("collect_with_sum.dmn")
      assert {:ok, ^definitions} = Validator.validate(definitions)
    end

    for fixture_name <- [
          "boxed_context_basic.dmn",
          "boxed_invocation_basic.dmn",
          "boxed_list_basic.dmn",
          "relation_basic.dmn",
          "boxed_conditional_basic.dmn",
          "boxed_filter_basic.dmn",
          "boxed_iterators.dmn",
          "with_dmndi.dmn"
        ] do
      test "CL3 fixture #{fixture_name} passes validation" do
        definitions = parse_fixture(unquote(fixture_name))
        assert {:ok, _} = Validator.validate(definitions)
      end
    end

    test "all 7 hit policies pass validation" do
      definitions = parse_fixture("all_hit_policies.dmn")
      assert {:ok, ^definitions} = Validator.validate(definitions)
    end

    test "valid CL1 model with BKMs, requirements, and item definitions passes" do
      definitions =
        minimal_definitions(
          decisions: [
            minimal_decision("D1",
              knowledge_requirements: [%KnowledgeRequirement{required_knowledge_id: "BKM_1"}],
              information_requirements: [%InformationRequirement{id: "ir1", required_decision_id: "D2"}]
            ),
            minimal_decision("D2")
          ],
          business_knowledge_models: [
            minimal_bkm("BKM_1")
          ],
          input_data: [%InputData{id: "ID1", name: "x"}],
          item_definitions: [%ItemDefinition{id: "IT1", name: "MyType", type_ref: "number"}]
        )

      assert {:ok, ^definitions} = Validator.validate(definitions)
    end
  end

  describe "validate/1 — value expression checks" do
    test "both-expressions fixture is valid (last expression wins in unified field)" do
      definitions = parse_fixture("invalid_both_expressions.dmn")
      assert {:ok, _definitions} = Validator.validate(definitions)
    end

    test "rejects decision with no value expression" do
      definitions = parse_fixture("invalid_no_expression.dmn")
      assert {:error, :validation_failed, %{violations: violations}} = Validator.validate(definitions)
      assert Enum.any?(violations, fn {code, _message} -> code == :invalid_decision end)
    end
  end

  describe "validate/1 — rule entry mismatch" do
    test "rejects rule with mismatched entry count" do
      definitions = parse_fixture("invalid_rule_mismatch.dmn")
      assert {:error, :validation_failed, %{violations: violations}} = Validator.validate(definitions)
      assert Enum.any?(violations, fn {code, _message} -> code == :rule_entry_mismatch end)
    end
  end

  describe "validate/1 — blank literal expression" do
    test "rejects blank literal expression text" do
      definitions = parse_fixture("invalid_blank_literal.dmn")
      assert {:error, :validation_failed, %{violations: violations}} = Validator.validate(definitions)
      assert Enum.any?(violations, fn {code, _message} -> code == :blank_literal_expression end)
    end
  end

  describe "validate/1 — BKM validation" do
    test "BKM without encapsulated_logic produces error" do
      definitions =
        minimal_definitions(
          business_knowledge_models: [minimal_bkm("BKM_1", encapsulated_logic: nil)]
        )

      assert {:error, :validation_failed, %{violations: violations}} = Validator.validate(definitions)
      assert Enum.any?(violations, fn {code, message} ->
        code == :invalid_bkm and message =~ "BKM_1" and message =~ "missing encapsulated logic"
      end)
    end

    test "BKM with non-FEEL function type produces error" do
      definitions =
        minimal_definitions(
          business_knowledge_models: [
            minimal_bkm("BKM_java",
              encapsulated_logic: %FunctionDefinition{
                id: "fn_java",
                type: :java,
                body: %LiteralExpression{id: "le_java", text: "1"}
              }
            )
          ]
        )

      assert {:error, :validation_failed, %{violations: violations}} = Validator.validate(definitions)
      assert Enum.any?(violations, fn {code, message} ->
        code == :invalid_function_kind and message =~ "BKM_java" and message =~ ":java"
      end)
    end

    test "BKM with empty function body produces error" do
      definitions =
        minimal_definitions(
          business_knowledge_models: [
            minimal_bkm("BKM_empty",
              encapsulated_logic: %FunctionDefinition{
                id: "fn_empty",
                type: :feel,
                body: nil
              }
            )
          ]
        )

      assert {:error, :validation_failed, %{violations: violations}} = Validator.validate(definitions)
      assert Enum.any?(violations, fn {code, message} ->
        code == :invalid_bkm and message =~ "BKM_empty" and message =~ "no body"
      end)
    end

    test "duplicate formal parameter names produces error" do
      definitions =
        minimal_definitions(
          business_knowledge_models: [
            minimal_bkm("BKM_dup",
              encapsulated_logic: %FunctionDefinition{
                id: "fn_dup",
                type: :feel,
                formal_parameters: [
                  %InformationItem{name: "x"},
                  %InformationItem{name: "y"},
                  %InformationItem{name: "x"}
                ],
                body: %LiteralExpression{id: "le_dup", text: "x + y"}
              }
            )
          ]
        )

      assert {:error, :validation_failed, %{violations: violations}} = Validator.validate(definitions)
      assert Enum.any?(violations, fn {code, message} ->
        code == :duplicate_formal_parameters and message =~ "BKM_dup" and message =~ "x"
      end)
    end
  end

  describe "validate/1 — KnowledgeRequirement references" do
    test "decision referencing non-existent BKM produces error" do
      definitions =
        minimal_definitions(
          decisions: [
            minimal_decision("D1",
              knowledge_requirements: [
                %KnowledgeRequirement{required_knowledge_id: "BKM_nonexistent"}
              ]
            )
          ]
        )

      assert {:error, :validation_failed, %{violations: violations}} = Validator.validate(definitions)
      assert Enum.any?(violations, fn {code, message} ->
        code == :invalid_knowledge_requirement and message =~ "D1" and message =~ "BKM_nonexistent"
      end)
    end

    test "BKM referencing non-existent BKM produces error" do
      definitions =
        minimal_definitions(
          business_knowledge_models: [
            minimal_bkm("BKM_1",
              knowledge_requirements: [
                %KnowledgeRequirement{required_knowledge_id: "BKM_ghost"}
              ]
            )
          ]
        )

      assert {:error, :validation_failed, %{violations: violations}} = Validator.validate(definitions)
      assert Enum.any?(violations, fn {code, message} ->
        code == :invalid_knowledge_requirement and message =~ "BKM_1" and message =~ "BKM_ghost"
      end)
    end

    test "valid KnowledgeRequirement passes" do
      definitions =
        minimal_definitions(
          decisions: [
            minimal_decision("D1",
              knowledge_requirements: [
                %KnowledgeRequirement{required_knowledge_id: "BKM_1"}
              ]
            )
          ],
          business_knowledge_models: [minimal_bkm("BKM_1")]
        )

      assert {:ok, _definitions} = Validator.validate(definitions)
    end
  end

  describe "validate/1 — AuthorityRequirement references" do
    test "AuthorityRequirement with unresolvable authority_id produces error" do
      definitions =
        minimal_definitions(
          decisions: [
            minimal_decision("D1",
              authority_requirements: [
                %AuthorityRequirement{required_authority_id: "KS_unknown"}
              ]
            )
          ]
        )

      assert {:error, :validation_failed, %{violations: violations}} = Validator.validate(definitions)
      assert Enum.any?(violations, fn {code, message} ->
        code == :invalid_authority_requirement and message =~ "KS_unknown"
      end)
    end

    test "AuthorityRequirement with unresolvable decision_id produces error" do
      definitions =
        minimal_definitions(
          decisions: [
            minimal_decision("D1",
              authority_requirements: [
                %AuthorityRequirement{required_decision_id: "D_unknown"}
              ]
            )
          ]
        )

      assert {:error, :validation_failed, %{violations: violations}} = Validator.validate(definitions)
      assert Enum.any?(violations, fn {code, message} ->
        code == :invalid_authority_requirement and message =~ "D_unknown"
      end)
    end

    test "AuthorityRequirement with unresolvable input_id produces error" do
      definitions =
        minimal_definitions(
          decisions: [
            minimal_decision("D1",
              authority_requirements: [
                %AuthorityRequirement{required_input_id: "ID_unknown"}
              ]
            )
          ]
        )

      assert {:error, :validation_failed, %{violations: violations}} = Validator.validate(definitions)
      assert Enum.any?(violations, fn {code, message} ->
        code == :invalid_authority_requirement and message =~ "ID_unknown"
      end)
    end

    test "valid AuthorityRequirement references pass" do
      definitions =
        minimal_definitions(
          decisions: [
            minimal_decision("D1",
              authority_requirements: [
                %AuthorityRequirement{
                  required_authority_id: "KS_1",
                  required_decision_id: "D2",
                  required_input_id: "ID_1"
                }
              ]
            ),
            minimal_decision("D2")
          ],
          knowledge_sources: [%KnowledgeSource{id: "KS_1", name: "Source"}],
          input_data: [%InputData{id: "ID_1", name: "x"}]
        )

      assert {:ok, _definitions} = Validator.validate(definitions)
    end
  end

  describe "validate/1 — decision variable (DMN spec)" do
    test "decision without variable passes validation — variable is optional per DMN 1.5" do
      definitions =
        minimal_definitions(
          decisions: [
            %Decision{
              id: "D_no_variable",
              expression: %LiteralExpression{id: "le1", text: "1"}
            }
          ]
        )

      assert {:ok, ^definitions} = Validator.validate(definitions)
    end
  end

  describe "validate/1 — duplicate element IDs (validation gap)" do
    test "duplicate decision IDs are not rejected at validation time" do
      definitions =
        minimal_definitions(
          decisions: [
            minimal_decision("D_duplicate", name: "First"),
            minimal_decision("D_duplicate", name: "Second")
          ]
        )

      assert {:ok, _} = Validator.validate(definitions)
      assert length(definitions.decisions) == 2
      assert Enum.count(definitions.decisions, &(&1.id == "D_duplicate")) == 2
    end
  end

  describe "validate/1 — InformationRequirement references" do
    test "InformationRequirement referencing unknown decision produces error" do
      definitions =
        minimal_definitions(
          decisions: [
            minimal_decision("D1",
              information_requirements: [
                %InformationRequirement{id: "ir1", required_decision_id: "D_nonexistent"}
              ]
            )
          ]
        )

      assert {:error, :validation_failed, %{violations: violations}} = Validator.validate(definitions)
      assert Enum.any?(violations, fn {code, message} ->
        code == :invalid_information_requirement and message =~ "D_nonexistent"
      end)
    end

    test "valid required_decision_id passes" do
      definitions =
        minimal_definitions(
          decisions: [
            minimal_decision("D1",
              information_requirements: [
                %InformationRequirement{id: "ir1", required_decision_id: "D2"}
              ]
            ),
            minimal_decision("D2")
          ]
        )

      assert {:ok, _definitions} = Validator.validate(definitions)
    end

    test "InformationRequirement referencing unknown InputData is not rejected at validation time" do
      definitions =
        minimal_definitions(
          decisions: [
            minimal_decision("D1",
              information_requirements: [
                %InformationRequirement{id: "ir1", required_input_id: "InputData_missing"}
              ]
            )
          ]
        )

      assert {:ok, _} = Validator.validate(definitions)
    end
  end

  describe "validate/1 — ItemDefinition type_ref" do
    test "ItemDefinition with unknown type_ref produces error" do
      definitions =
        minimal_definitions(
          item_definitions: [
            %ItemDefinition{id: "IT1", name: "BadType", type_ref: "nonexistentType"}
          ]
        )

      assert {:error, :validation_failed, %{violations: violations}} = Validator.validate(definitions)
      assert Enum.any?(violations, fn {code, message} ->
        code == :invalid_item_definition and message =~ "nonexistentType"
      end)
    end

    test "ItemDefinition with built-in FEEL type passes" do
      definitions =
        minimal_definitions(
          item_definitions: [
            %ItemDefinition{id: "IT1", name: "NumType", type_ref: "number"},
            %ItemDefinition{id: "IT2", name: "StrType", type_ref: "string"},
            %ItemDefinition{id: "IT3", name: "DateType", type_ref: "date"},
            %ItemDefinition{id: "IT4", name: "AnyType", type_ref: "Any"}
          ]
        )

      assert {:ok, _definitions} = Validator.validate(definitions)
    end

    test "ItemDefinition referencing another ItemDefinition by name passes" do
      definitions =
        minimal_definitions(
          item_definitions: [
            %ItemDefinition{id: "IT1", name: "BaseType", type_ref: "number"},
            %ItemDefinition{id: "IT2", name: "DerivedType", type_ref: "BaseType"}
          ]
        )

      assert {:ok, _definitions} = Validator.validate(definitions)
    end

    test "ItemDefinition with nil type_ref passes" do
      definitions =
        minimal_definitions(
          item_definitions: [
            %ItemDefinition{id: "IT1", name: "OpenType", type_ref: nil}
          ]
        )

      assert {:ok, _definitions} = Validator.validate(definitions)
    end
  end

  describe "validate/1 — Import validation" do
    test "Import with blank namespace produces error" do
      definitions =
        minimal_definitions(
          imports: [%Import{namespace: "", import_type: "http://www.omg.org/spec/DMN/20180521/MODEL/"}]
        )

      assert {:error, :validation_failed, %{violations: violations}} = Validator.validate(definitions)
      assert Enum.any?(violations, fn {code, _message} -> code == :invalid_import end)
    end

    test "Import with valid namespace passes" do
      definitions =
        minimal_definitions(
          imports: [%Import{namespace: "https://example.com/model", import_type: "http://www.omg.org/spec/DMN/20180521/MODEL/"}]
        )

      assert {:ok, _definitions} = Validator.validate(definitions)
    end
  end

  describe "validate/1 — DRG cycle detection" do
    test "decision cycle produces error" do
      definitions =
        minimal_definitions(
          decisions: [
            minimal_decision("D_A",
              information_requirements: [
                %InformationRequirement{id: "ir1", required_decision_id: "D_B"}
              ]
            ),
            minimal_decision("D_B",
              information_requirements: [
                %InformationRequirement{id: "ir2", required_decision_id: "D_A"}
              ]
            )
          ]
        )

      assert {:error, :validation_failed, %{violations: violations}} = Validator.validate(definitions)
      assert Enum.any?(violations, fn {code, _message} -> code == :drg_cycle end)
    end

    test "BKM cycle produces error" do
      definitions =
        minimal_definitions(
          business_knowledge_models: [
            minimal_bkm("BKM_A",
              knowledge_requirements: [
                %KnowledgeRequirement{required_knowledge_id: "BKM_B"}
              ]
            ),
            minimal_bkm("BKM_B",
              knowledge_requirements: [
                %KnowledgeRequirement{required_knowledge_id: "BKM_A"}
              ]
            )
          ]
        )

      assert {:error, :validation_failed, %{violations: violations}} = Validator.validate(definitions)
      assert Enum.any?(violations, fn {code, _message} ->
        code == :bkm_cycle
      end)
    end

    test "acyclic DRG passes" do
      definitions =
        minimal_definitions(
          decisions: [
            minimal_decision("D1",
              information_requirements: [
                %InformationRequirement{id: "ir1", required_decision_id: "D2"}
              ]
            ),
            minimal_decision("D2")
          ],
          business_knowledge_models: [
            minimal_bkm("BKM_1",
              knowledge_requirements: [
                %KnowledgeRequirement{required_knowledge_id: "BKM_2"}
              ]
            ),
            minimal_bkm("BKM_2")
          ]
        )

      assert {:ok, _definitions} = Validator.validate(definitions)
    end
  end

  describe "validate/1 — comprehensive model from fixtures" do
    test "comprehensive DRD fixture passes" do
      definitions = parse_fixture("comprehensive_drd.dmn")
      assert {:ok, _definitions} = Validator.validate(definitions)
    end

    test "BKM invocation literal fixture passes" do
      definitions = parse_fixture("bkm_invocation_literal.dmn")
      assert {:ok, _definitions} = Validator.validate(definitions)
    end
  end

  describe "validate/1 — boxed context" do
    test "rejects empty context_entries" do
      definitions =
        minimal_definitions(
          decisions: [
            %Decision{
              id: "D1",
              expression: %BfwEngine.DMN.Model.BoxedContext{id: "ctx", context_entries: []}
            }
          ]
        )

      assert {:error, :validation_failed, %{violations: violations}} = Validator.validate(definitions)

      assert Enum.any?(violations, fn {code, _message} ->
               code == :empty_context
             end)
    end

    test "rejects context entry without expression" do
      definitions =
        minimal_definitions(
          decisions: [
            %Decision{
              id: "D1",
              expression: %BfwEngine.DMN.Model.BoxedContext{
                id: "ctx",
                context_entries: [
                  %BfwEngine.DMN.Model.ContextEntry{
                    variable: %InformationItem{name: "x"},
                    expression: nil
                  }
                ]
              }
            }
          ]
        )

      assert {:error, :validation_failed, %{violations: violations}} = Validator.validate(definitions)

      assert Enum.any?(violations, fn {code, _message} ->
               code == :missing_context_entry_expression
             end)
    end
  end

  describe "validate/1 — boxed list" do
    test "rejects empty list" do
      definitions =
        minimal_definitions(
          decisions: [
            %Decision{
              id: "D1",
              expression: %BfwEngine.DMN.Model.BoxedList{id: "list", elements: []}
            }
          ]
        )

      assert {:error, :validation_failed, %{violations: violations}} = Validator.validate(definitions)

      assert Enum.any?(violations, fn {code, _message} ->
               code == :empty_list
             end)
    end
  end

  describe "validate/1 — boxed conditional" do
    test "rejects conditional with missing then branch" do
      definitions =
        minimal_definitions(
          decisions: [
            %Decision{
              id: "D1",
              expression: %BoxedConditional{
                id: "cond",
                if_expression: %LiteralExpression{id: "le1", text: "true"},
                then_expression: nil,
                else_expression: %LiteralExpression{id: "le2", text: "1"}
              }
            }
          ]
        )

      assert {:error, :validation_failed, %{violations: violations}} = Validator.validate(definitions)

      assert Enum.any?(violations, fn {code, _message} ->
               code == :missing_conditional_branch
             end)
    end

    test "rejects conditional with missing if branch" do
      definitions =
        minimal_definitions(
          decisions: [
            %Decision{
              id: "D1",
              expression: %BoxedConditional{
                id: "cond",
                if_expression: nil,
                then_expression: %LiteralExpression{id: "le1", text: "1"},
                else_expression: %LiteralExpression{id: "le2", text: "2"}
              }
            }
          ]
        )

      assert {:error, :validation_failed, %{violations: violations}} = Validator.validate(definitions)

      assert Enum.any?(violations, fn {code, _message} ->
               code == :missing_conditional_branch
             end)
    end

    test "rejects conditional with missing else branch" do
      definitions =
        minimal_definitions(
          decisions: [
            %Decision{
              id: "D1",
              expression: %BoxedConditional{
                id: "cond",
                if_expression: %LiteralExpression{id: "le1", text: "true"},
                then_expression: %LiteralExpression{id: "le2", text: "1"},
                else_expression: nil
              }
            }
          ]
        )

      assert {:error, :validation_failed, %{violations: violations}} = Validator.validate(definitions)

      assert Enum.any?(violations, fn {code, _message} ->
               code == :missing_conditional_branch
             end)
    end
  end

  describe "validate/1 — boxed invocation" do
    test "rejects invocation with nil called_function" do
      definitions =
        minimal_definitions(
          decisions: [
            %Decision{
              id: "D1",
              expression: %BoxedInvocation{id: "inv", called_function: nil, bindings: []}
            }
          ]
        )

      assert {:error, :validation_failed, %{violations: violations}} = Validator.validate(definitions)

      assert Enum.any?(violations, fn {code, _message} ->
               code == :missing_called_function
             end)
    end

    test "rejects invocation with blank called_function" do
      definitions =
        minimal_definitions(
          decisions: [
            %Decision{
              id: "D1",
              expression: %BoxedInvocation{id: "inv", called_function: "  ", bindings: []}
            }
          ]
        )

      assert {:error, :validation_failed, %{violations: violations}} = Validator.validate(definitions)

      assert Enum.any?(violations, fn {code, _message} ->
               code == :missing_called_function
             end)
    end

    test "rejects binding with nil parameter" do
      definitions =
        minimal_definitions(
          decisions: [
            %Decision{
              id: "D1",
              expression: %BoxedInvocation{
                id: "inv",
                called_function: "MyBKM",
                bindings: [
                  %Binding{
                    parameter: nil,
                    expression: %LiteralExpression{id: "le1", text: "1"}
                  }
                ]
              },
              knowledge_requirements: [
                %KnowledgeRequirement{required_knowledge_id: "BKM_1"}
              ]
            }
          ],
          business_knowledge_models: [minimal_bkm("BKM_1", name: "MyBKM")]
        )

      assert {:error, :validation_failed, %{violations: violations}} = Validator.validate(definitions)

      assert Enum.any?(violations, fn {code, _message} ->
               code == :missing_binding_parameter
             end)
    end

    test "rejects binding with nil expression" do
      definitions =
        minimal_definitions(
          decisions: [
            %Decision{
              id: "D1",
              expression: %BoxedInvocation{
                id: "inv",
                called_function: "MyBKM",
                bindings: [
                  %Binding{
                    parameter: %InformationItem{name: "x"},
                    expression: nil
                  }
                ]
              },
              knowledge_requirements: [
                %KnowledgeRequirement{required_knowledge_id: "BKM_1"}
              ]
            }
          ],
          business_knowledge_models: [
            minimal_bkm("BKM_1",
              name: "MyBKM",
              encapsulated_logic: %FunctionDefinition{
                id: "fn_bkm",
                type: :feel,
                formal_parameters: [%InformationItem{name: "x"}],
                body: %LiteralExpression{id: "le_bkm", text: "x"}
              }
            )
          ]
        )

      assert {:error, :validation_failed, %{violations: violations}} = Validator.validate(definitions)

      assert Enum.any?(violations, fn {code, _message} ->
               code == :missing_binding_expression
             end)
    end
  end

  describe "validate/1 — relation" do
    test "rejects relation with zero columns" do
      definitions =
        minimal_definitions(
          decisions: [
            %Decision{
              id: "D1",
              expression: %Relation{id: "rel", columns: [], rows: []}
            }
          ]
        )

      assert {:error, :validation_failed, %{violations: violations}} = Validator.validate(definitions)

      assert Enum.any?(violations, fn {code, _message} ->
               code == :empty_relation_columns
             end)
    end
  end

  describe "validate/1 — boxed filter" do
    test "rejects filter with missing match_expression" do
      definitions =
        minimal_definitions(
          decisions: [
            %Decision{
              id: "D1",
              expression: %BoxedFilter{
                id: "filter",
                in_expression: %LiteralExpression{id: "le1", text: "[1,2,3]"},
                match_expression: nil
              }
            }
          ]
        )

      assert {:error, :validation_failed, %{violations: violations}} = Validator.validate(definitions)

      assert Enum.any?(violations, fn {code, _message} ->
               code == :missing_filter_expression
             end)
    end
  end

  describe "validate/1 — boxed iterator" do
    test "rejects BoxedFor with blank iterator variable" do
      definitions =
        minimal_definitions(
          decisions: [
            %Decision{
              id: "D1",
              expression: %BoxedFor{
                id: "for_1",
                iterator_variable: "",
                in_expression: %LiteralExpression{id: "le1", text: "[1]"},
                return_expression: %LiteralExpression{id: "le2", text: "1"}
              }
            }
          ]
        )

      assert {:error, :validation_failed, %{violations: violations}} = Validator.validate(definitions)

      assert Enum.any?(violations, fn {code, _message} ->
               code == :missing_iterator_variable
             end)
    end

    test "rejects BoxedFor with missing in_expression" do
      definitions =
        minimal_definitions(
          decisions: [
            %Decision{
              id: "D1",
              expression: %BoxedFor{
                id: "for_1",
                iterator_variable: "item",
                in_expression: nil,
                return_expression: %LiteralExpression{id: "le2", text: "item"}
              }
            }
          ]
        )

      assert {:error, :validation_failed, %{violations: violations}} = Validator.validate(definitions)

      assert Enum.any?(violations, fn {code, _message} ->
               code == :missing_iterator_expression
             end)
    end

    test "rejects BoxedFor with missing return_expression" do
      definitions =
        minimal_definitions(
          decisions: [
            %Decision{
              id: "D1",
              expression: %BoxedFor{
                id: "for_1",
                iterator_variable: "item",
                in_expression: %LiteralExpression{id: "le1", text: "[1,2,3]"},
                return_expression: nil
              }
            }
          ]
        )

      assert {:error, :validation_failed, %{violations: violations}} = Validator.validate(definitions)

      assert Enum.any?(violations, fn {code, _message} ->
               code == :missing_iterator_expression
             end)
    end

    test "rejects BoxedEvery with missing in_expression" do
      definitions =
        minimal_definitions(
          decisions: [
            %Decision{
              id: "D1",
              expression: %BoxedEvery{
                id: "every_1",
                iterator_variable: "item",
                in_expression: nil,
                satisfies_expression: %LiteralExpression{id: "le2", text: "item > 0"}
              }
            }
          ]
        )

      assert {:error, :validation_failed, %{violations: violations}} = Validator.validate(definitions)

      assert Enum.any?(violations, fn {code, _message} ->
               code == :missing_iterator_expression
             end)
    end

    test "rejects BoxedEvery with missing satisfies_expression" do
      definitions =
        minimal_definitions(
          decisions: [
            %Decision{
              id: "D1",
              expression: %BoxedEvery{
                id: "every_1",
                iterator_variable: "item",
                in_expression: %LiteralExpression{id: "le1", text: "[1,2,3]"},
                satisfies_expression: nil
              }
            }
          ]
        )

      assert {:error, :validation_failed, %{violations: violations}} = Validator.validate(definitions)

      assert Enum.any?(violations, fn {code, _message} ->
               code == :missing_iterator_expression
             end)
    end

    test "rejects BoxedSome with missing in_expression" do
      definitions =
        minimal_definitions(
          decisions: [
            %Decision{
              id: "D1",
              expression: %BoxedSome{
                id: "some_1",
                iterator_variable: "item",
                in_expression: nil,
                satisfies_expression: %LiteralExpression{id: "le2", text: "item > 0"}
              }
            }
          ]
        )

      assert {:error, :validation_failed, %{violations: violations}} = Validator.validate(definitions)

      assert Enum.any?(violations, fn {code, _message} ->
               code == :missing_iterator_expression
             end)
    end

    test "rejects BoxedSome with missing satisfies_expression" do
      definitions =
        minimal_definitions(
          decisions: [
            %Decision{
              id: "D1",
              expression: %BoxedSome{
                id: "some_1",
                iterator_variable: "item",
                in_expression: %LiteralExpression{id: "le1", text: "[1,2,3]"},
                satisfies_expression: nil
              }
            }
          ]
        )

      assert {:error, :validation_failed, %{violations: violations}} = Validator.validate(definitions)

      assert Enum.any?(violations, fn {code, _message} ->
               code == :missing_iterator_expression
             end)
    end
  end

  describe "validate/1 — standalone function definition" do
    test "rejects standalone FunctionDefinition with non-FEEL type" do
      definitions =
        minimal_definitions(
          decisions: [
            %Decision{
              id: "D1",
              expression: %FunctionDefinition{
                id: "fn_java",
                type: :java,
                body: %LiteralExpression{id: "le1", text: "1"}
              }
            }
          ]
        )

      assert {:error, :validation_failed, %{violations: violations}} = Validator.validate(definitions)

      assert Enum.any?(violations, fn {code, _message} ->
               code == :unsupported_function_kind
             end)
    end

    test "rejects standalone FunctionDefinition with nil body" do
      definitions =
        minimal_definitions(
          decisions: [
            %Decision{
              id: "D1",
              expression: %FunctionDefinition{id: "fn_empty", type: :feel, body: nil}
            }
          ]
        )

      assert {:error, :validation_failed, %{violations: violations}} = Validator.validate(definitions)

      assert Enum.any?(violations, fn {code, _message} ->
               code == :missing_function_body
             end)
    end

    test "rejects standalone FunctionDefinition with duplicate formal parameters" do
      definitions =
        minimal_definitions(
          decisions: [
            %Decision{
              id: "D1",
              expression: %FunctionDefinition{
                id: "fn_dup",
                type: :feel,
                formal_parameters: [
                  %InformationItem{name: "amount"},
                  %InformationItem{name: "rate"},
                  %InformationItem{name: "amount"}
                ],
                body: %LiteralExpression{id: "le_dup", text: "amount * rate"}
              }
            }
          ]
        )

      assert {:error, :validation_failed, %{violations: violations}} = Validator.validate(definitions)

      assert Enum.any?(violations, fn {code, message} ->
               code == :duplicate_formal_parameters and message =~ "amount"
             end)
    end
  end

  describe "validate/1 — CL3 boxed expression gaps" do
    test "rejects boxed context with duplicate variable names" do
      definitions = %Definitions{
        decisions: [
          %Decision{
            id: "D1",
            expression: %BoxedContext{
              context_entries: [
                %ContextEntry{
                  variable: %InformationItem{name: "x"},
                  expression: %LiteralExpression{text: "1"}
                },
                %ContextEntry{
                  variable: %InformationItem{name: "x"},
                  expression: %LiteralExpression{text: "2"}
                }
              ]
            }
          }
        ],
        raw_xml: ""
      }

      assert {:error, :validation_failed, %{violations: violations}} = Validator.validate(definitions)

      assert Enum.any?(violations, fn {type, _} ->
               type == :duplicate_context_variables
             end)
    end

    test "rejects relation with row/column count mismatch" do
      definitions = %Definitions{
        decisions: [
          %Decision{
            id: "D1",
            expression: %Relation{
              columns: [
                %InformationItem{name: "col1"},
                %InformationItem{name: "col2"}
              ],
              rows: [
                [%LiteralExpression{text: "1"}]
              ]
            }
          }
        ],
        raw_xml: ""
      }

      assert {:error, :validation_failed, %{violations: violations}} = Validator.validate(definitions)

      assert Enum.any?(violations, fn {type, _} ->
               type == :relation_row_column_mismatch
             end)
    end

    test "rejects boxed filter with missing in_expression" do
      definitions = %Definitions{
        decisions: [
          %Decision{
            id: "D1",
            expression: %BoxedFilter{
              in_expression: nil,
              match_expression: %LiteralExpression{text: "true"}
            }
          }
        ],
        raw_xml: ""
      }

      assert {:error, :validation_failed, %{violations: violations}} = Validator.validate(definitions)

      assert Enum.any?(violations, fn {type, _} ->
               type == :missing_filter_expression
             end)
    end

    test "rejects boxed every with blank iterator variable" do
      definitions = %Definitions{
        decisions: [
          %Decision{
            id: "D1",
            expression: %BoxedEvery{
              iterator_variable: "",
              in_expression: %LiteralExpression{text: "[1,2,3]"},
              satisfies_expression: %LiteralExpression{text: "true"}
            }
          }
        ],
        raw_xml: ""
      }

      assert {:error, :validation_failed, %{violations: violations}} = Validator.validate(definitions)

      assert Enum.any?(violations, fn {type, _} ->
               type == :missing_iterator_variable
             end)
    end

    test "rejects boxed some with blank iterator variable" do
      definitions = %Definitions{
        decisions: [
          %Decision{
            id: "D1",
            expression: %BoxedSome{
              iterator_variable: "",
              in_expression: %LiteralExpression{text: "[1,2,3]"},
              satisfies_expression: %LiteralExpression{text: "true"}
            }
          }
        ],
        raw_xml: ""
      }

      assert {:error, :validation_failed, %{violations: violations}} = Validator.validate(definitions)

      assert Enum.any?(violations, fn {type, _} ->
               type == :missing_iterator_variable
             end)
    end

    test "rejects boxed invocation referencing non-existent BKM" do
      definitions = %Definitions{
        decisions: [
          %Decision{
            id: "D1",
            expression: %BoxedInvocation{
              called_function: "NonExistentBKM",
              bindings: []
            }
          }
        ],
        business_knowledge_models: [],
        raw_xml: ""
      }

      assert {:error, :validation_failed, %{violations: violations}} = Validator.validate(definitions)

      assert Enum.any?(violations, fn {type, _} ->
               type == :invalid_invocation_reference
             end)
    end

    test "rejects boxed invocation with mismatched parameter names" do
      definitions = %Definitions{
        decisions: [
          %Decision{
            id: "D1",
            expression: %BoxedInvocation{
              called_function: "MyBKM",
              bindings: [
                %Binding{
                  parameter: %InformationItem{name: "wrong_param"},
                  expression: %LiteralExpression{text: "1"}
                }
              ]
            },
            knowledge_requirements: [
              %KnowledgeRequirement{required_knowledge_id: "BKM_1"}
            ]
          }
        ],
        business_knowledge_models: [
          %BusinessKnowledgeModel{
            id: "BKM_1",
            name: "MyBKM",
            encapsulated_logic: %FunctionDefinition{
              type: :feel,
              formal_parameters: [%InformationItem{name: "correct_param"}],
              body: %LiteralExpression{text: "correct_param * 2"}
            }
          }
        ],
        raw_xml: ""
      }

      assert {:error, :validation_failed, %{violations: violations}} = Validator.validate(definitions)

      assert Enum.any?(violations, fn {type, _} ->
               type == :invalid_invocation_parameter
             end)
    end
  end

  describe "validate/1 — decision service" do
    test "valid decision service passes" do
      definitions =
        minimal_definitions(
          decisions: [minimal_decision("D1"), minimal_decision("D2",
            information_requirements: [%InformationRequirement{required_decision_id: "D1"}]
          )],
          input_data: [%InputData{id: "ID1", name: "Input1"}],
          decision_services: [
            %DecisionService{
              id: "DS1",
              name: "Service 1",
              output_decisions: ["D2"],
              encapsulated_decisions: ["D1"],
              input_data: ["ID1"]
            }
          ]
        )

      assert {:ok, _} = Validator.validate(definitions)
    end

    test "rejects decision service with empty output_decisions" do
      definitions =
        minimal_definitions(
          decision_services: [
            %DecisionService{id: "DS_empty", output_decisions: []}
          ]
        )

      assert {:error, :validation_failed, %{violations: violations}} = Validator.validate(definitions)

      assert Enum.any?(violations, fn {type, message} ->
               type == :invalid_decision_service and
                 message =~ "at least one outputDecision"
             end)
    end

    test "rejects decision service referencing non-existent decision" do
      definitions =
        minimal_definitions(
          decisions: [minimal_decision("D1")],
          decision_services: [
            %DecisionService{
              id: "DS_bad_ref",
              output_decisions: ["D_nonexistent"]
            }
          ]
        )

      assert {:error, :validation_failed, %{violations: violations}} = Validator.validate(definitions)

      assert Enum.any?(violations, fn {type, message} ->
               type == :invalid_decision_service and
                 message =~ "unknown Decision" and
                 message =~ "D_nonexistent"
             end)
    end

    test "rejects decision service referencing non-existent input data" do
      definitions =
        minimal_definitions(
          decisions: [minimal_decision("D1")],
          decision_services: [
            %DecisionService{
              id: "DS_bad_input",
              output_decisions: ["D1"],
              input_data: ["ID_nonexistent"]
            }
          ]
        )

      assert {:error, :validation_failed, %{violations: violations}} = Validator.validate(definitions)

      assert Enum.any?(violations, fn {type, message} ->
               type == :invalid_decision_service and
                 message =~ "unknown InputData" and
                 message =~ "ID_nonexistent"
             end)
    end

    test "rejects decision with same ID in both output and encapsulated" do
      definitions =
        minimal_definitions(
          decisions: [minimal_decision("D1")],
          decision_services: [
            %DecisionService{
              id: "DS_overlap",
              output_decisions: ["D1"],
              encapsulated_decisions: ["D1"]
            }
          ]
        )

      assert {:error, :validation_failed, %{violations: violations}} = Validator.validate(definitions)

      assert Enum.any?(violations, fn {type, message} ->
               type == :invalid_decision_service and
                 message =~ "both outputDecisions and encapsulatedDecisions"
             end)
    end

    test "rejects input decision that is also an output decision" do
      definitions =
        minimal_definitions(
          decisions: [minimal_decision("D1"), minimal_decision("D2")],
          decision_services: [
            %DecisionService{
              id: "DS_bad_input_dec",
              output_decisions: ["D1"],
              input_decisions: ["D1"]
            }
          ]
        )

      assert {:error, :validation_failed, %{violations: violations}} = Validator.validate(definitions)

      assert Enum.any?(violations, fn {type, message} ->
               type == :invalid_decision_service and
                 message =~ "inputDecision" and
                 message =~ "outputDecisions or encapsulatedDecisions"
             end)
    end

    test "valid fixture passes validation" do
      definitions = parse_fixture("decision_service_basic.dmn")
      assert {:ok, _} = Validator.validate(definitions)
    end

    test "nested fixture passes validation" do
      definitions = parse_fixture("decision_service_nested.dmn")
      assert {:ok, _} = Validator.validate(definitions)
    end
  end

  describe "validate/1 — decision table structural rules (inline XML)" do
    test "rejects decision table with invalid hit policy" do
      # Parser maps unknown hitPolicy strings (e.g. "BOGUS") to UNIQUE by default,
      # so inject an invalid atom after parse to exercise the validator rule.
      definitions = parse_inline_dmn("""
        <decision id="Decision_hit_policy" name="Hit Policy Test">
          <decisionTable id="dt_hit_policy" hitPolicy="BOGUS">
            <input id="Input_1" label="Age">
              <inputExpression typeRef="number"><text>age</text></inputExpression>
            </input>
            <output id="Output_1" label="Result" name="result" typeRef="string"/>
            <rule id="Rule_1">
              <inputEntry id="IE_1"><text>-</text></inputEntry>
              <outputEntry id="OE_1"><text>"ok"</text></outputEntry>
            </rule>
          </decisionTable>
        </decision>
      """)

      [decision] = definitions.decisions
      invalid_table = %{decision.expression | hit_policy: :bogus}
      invalid_decision = %{decision | expression: invalid_table}
      definitions = %{definitions | decisions: [invalid_decision]}

      assert {:error, :validation_failed, %{violations: violations}} = Validator.validate(definitions)

      assert Enum.any?(violations, fn {code, message} ->
               code == :invalid_hit_policy and message =~ "dt_hit_policy" and message =~ "bogus"
             end)
    end

    test "rejects decision table with no rules" do
      definitions = parse_inline_dmn("""
        <decision id="Decision_no_rules" name="No Rules">
          <decisionTable id="dt_no_rules" hitPolicy="UNIQUE">
            <input id="Input_1" label="Age">
              <inputExpression typeRef="number"><text>age</text></inputExpression>
            </input>
            <output id="Output_1" label="Result" name="result" typeRef="string"/>
          </decisionTable>
        </decision>
      """)

      assert {:error, :validation_failed, %{violations: violations}} = Validator.validate(definitions)

      assert Enum.any?(violations, fn {code, message} ->
               code == :missing_rules and message =~ "dt_no_rules"
             end)
    end

    test "rejects decision table with no inputs" do
      definitions = parse_inline_dmn("""
        <decision id="Decision_no_inputs" name="No Inputs">
          <decisionTable id="dt_no_inputs" hitPolicy="UNIQUE">
            <output id="Output_1" label="Result" name="result" typeRef="string"/>
            <rule id="Rule_1">
              <outputEntry id="OE_1"><text>"ok"</text></outputEntry>
            </rule>
          </decisionTable>
        </decision>
      """)

      assert {:error, :validation_failed, %{violations: violations}} = Validator.validate(definitions)

      assert Enum.any?(violations, fn {code, message} ->
               code == :missing_inputs and message =~ "dt_no_inputs"
             end)
    end

    test "rejects decision table with no outputs" do
      definitions = parse_inline_dmn("""
        <decision id="Decision_no_outputs" name="No Outputs">
          <decisionTable id="dt_no_outputs" hitPolicy="UNIQUE">
            <input id="Input_1" label="Age">
              <inputExpression typeRef="number"><text>age</text></inputExpression>
            </input>
            <rule id="Rule_1">
              <inputEntry id="IE_1"><text>-</text></inputEntry>
            </rule>
          </decisionTable>
        </decision>
      """)

      assert {:error, :validation_failed, %{violations: violations}} = Validator.validate(definitions)

      assert Enum.any?(violations, fn {code, message} ->
               code == :missing_outputs and message =~ "dt_no_outputs"
             end)
    end

    test "rejects non-COLLECT decision table with aggregation function" do
      definitions = parse_inline_dmn("""
        <decision id="Decision_bad_aggregation" name="Bad Aggregation">
          <decisionTable id="dt_bad_aggregation" hitPolicy="UNIQUE" aggregation="SUM">
            <input id="Input_1" label="Amount">
              <inputExpression typeRef="number"><text>amount</text></inputExpression>
            </input>
            <output id="Output_1" label="Result" name="result" typeRef="number"/>
            <rule id="Rule_1">
              <inputEntry id="IE_1"><text>-</text></inputEntry>
              <outputEntry id="OE_1"><text>amount</text></outputEntry>
            </rule>
          </decisionTable>
        </decision>
      """)

      assert {:error, :validation_failed, %{violations: violations}} = Validator.validate(definitions)

      assert Enum.any?(violations, fn {code, message} ->
               code == :invalid_aggregation and
                 message =~ "dt_bad_aggregation" and
                 message =~ "hit policy is not COLLECT"
             end)
    end
  end
end
