defmodule BfwEngine.DMN.ParserTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias BfwEngine.DMN.Model.AuthorityRequirement
  alias BfwEngine.DMN.Model.BoxedConditional
  alias BfwEngine.DMN.Model.BoxedContext
  alias BfwEngine.DMN.Model.BoxedEvery
  alias BfwEngine.DMN.Model.BoxedFilter
  alias BfwEngine.DMN.Model.BoxedFor
  alias BfwEngine.DMN.Model.BoxedInvocation
  alias BfwEngine.DMN.Model.BoxedList
  alias BfwEngine.DMN.Model.BoxedSome
  alias BfwEngine.DMN.Model.BusinessKnowledgeModel
  alias BfwEngine.DMN.Model.DecisionService
  alias BfwEngine.DMN.Model.DecisionTable
  alias BfwEngine.DMN.Model.Definitions
  alias BfwEngine.DMN.Model.FunctionDefinition
  alias BfwEngine.DMN.Model.Import
  alias BfwEngine.DMN.Model.InformationItem
  alias BfwEngine.DMN.Model.InformationRequirement
  alias BfwEngine.DMN.Model.ItemDefinition
  alias BfwEngine.DMN.Model.KnowledgeRequirement
  alias BfwEngine.DMN.Model.KnowledgeSource
  alias BfwEngine.DMN.Model.LiteralExpression
  alias BfwEngine.DMN.Model.Relation
  alias BfwEngine.DMN.Parser

  @fixtures_dir Path.join([__DIR__, "..", "..", "fixtures", "dmns"])

  defp read_fixture(name), do: File.read!(Path.join(@fixtures_dir, name))

  describe "parse/1 — happy paths" do
    test "parses simple UNIQUE decision table" do
      {:ok, %Definitions{} = definitions} = Parser.parse(read_fixture("simple_unique.dmn"))

      assert definitions.id == "definitions_discount"
      assert definitions.name == "Discount Rules"
      assert length(definitions.decisions) == 1

      [decision] = definitions.decisions
      assert decision.id == "Decision_discount"
      assert decision.name == "Discount Percentage"
      assert %DecisionTable{} = decision.expression
      assert decision.expression.hit_policy == :unique
      assert length(decision.expression.inputs) == 1
      assert length(decision.expression.outputs) == 1
      assert length(decision.expression.rules) == 3

      [input] = decision.expression.inputs
      assert input.id == "Input_1"
      assert input.label == "Customer Age"
      assert input.type_ref == "number"
      assert input.input_expression == "age"
    end

    test "parses decision with literal expression (G8)" do
      {:ok, definitions} = Parser.parse(read_fixture("literal_expression.dmn"))

      [decision] = definitions.decisions
      assert %LiteralExpression{} = decision.expression
      assert decision.expression.text != ""
    end

    test "parses all 7 hit policies" do
      {:ok, definitions} = Parser.parse(read_fixture("all_hit_policies.dmn"))
      hit_policies = Enum.map(definitions.decisions, & &1.expression.hit_policy)
      assert Enum.sort(hit_policies) == [:any, :collect, :first, :output_order, :priority, :rule_order, :unique]
    end

    test "parses input data with variable typeRef" do
      {:ok, definitions} = Parser.parse(read_fixture("with_input_data.dmn"))
      assert definitions.input_data != []
      assert Enum.all?(definitions.input_data, fn input_data -> input_data.name != nil end)
    end

    test "parses information requirements" do
      {:ok, definitions} = Parser.parse(read_fixture("simple_unique.dmn"))
      [decision] = definitions.decisions
      assert [%InformationRequirement{required_input_id: "InputData_age"}] = decision.information_requirements
    end

    test "preserves raw_xml in definitions" do
      xml = read_fixture("simple_unique.dmn")
      {:ok, definitions} = Parser.parse(xml)
      assert definitions.raw_xml == xml
    end

    test "parses FIRST hit policy with multiple inputs" do
      {:ok, definitions} = Parser.parse(read_fixture("multi_input_first.dmn"))
      [decision] = definitions.decisions
      assert decision.expression.hit_policy == :first
      assert length(decision.expression.inputs) == 3
    end

    test "parses COLLECT with SUM aggregation" do
      {:ok, definitions} = Parser.parse(read_fixture("collect_with_sum.dmn"))
      [decision] = definitions.decisions
      assert decision.expression.hit_policy == :collect
      assert decision.expression.aggregation == :sum
    end

    test "parses output column attributes (name, typeRef, label)" do
      {:ok, definitions} = Parser.parse(read_fixture("simple_unique.dmn"))
      [decision] = definitions.decisions
      [output] = decision.expression.outputs
      assert output.id == "Output_1"
      assert output.name == "discount"
      assert output.type_ref == "number"
      assert output.label == "Discount"
    end

    test "parses rule descriptions" do
      {:ok, definitions} = Parser.parse(read_fixture("multi_input_first.dmn"))
      [decision] = definitions.decisions
      rules_with_description = Enum.filter(decision.expression.rules, & &1.description)
      assert rules_with_description != []
    end

    test "parses decision with both table and literal (structurally invalid — last expression wins)" do
      {:ok, definitions} = Parser.parse(read_fixture("invalid_both_expressions.dmn"))
      [decision] = definitions.decisions
      assert %LiteralExpression{} = decision.expression
    end

    test "parses blank literal expression text" do
      {:ok, definitions} = Parser.parse(read_fixture("invalid_blank_literal.dmn"))
      [decision] = definitions.decisions
      assert %LiteralExpression{text: ""} = decision.expression
    end

    test "parses RULE ORDER with multiple outputs" do
      {:ok, definitions} = Parser.parse(read_fixture("multi_output_rule_order.dmn"))
      [decision] = definitions.decisions
      assert decision.expression.hit_policy == :rule_order
      assert length(decision.expression.outputs) == 3
    end

    test "parses PRIORITY hit policy with output values" do
      {:ok, definitions} = Parser.parse(read_fixture("priority_hit_policy.dmn"))
      [decision] = definitions.decisions
      assert decision.expression.hit_policy == :priority
      [output] = decision.expression.outputs
      assert output.output_values != nil
    end

    test "parses mixed model with both table and literal decisions" do
      {:ok, definitions} = Parser.parse(read_fixture("mixed_decisions.dmn"))
      assert length(definitions.decisions) == 2
      [table_decision, literal_decision] = definitions.decisions
      assert %DecisionTable{} = table_decision.expression
      assert %LiteralExpression{} = literal_decision.expression
    end
  end

  # --- Phase 4: BKM parsing (2A) --------------------------------------------

  describe "parse/1 — businessKnowledgeModel" do
    test "parses BKM with encapsulatedLogic containing a decisionTable" do
      {:ok, definitions} = Parser.parse(read_fixture("bkm_with_decision_table.dmn"))

      assert length(definitions.business_knowledge_models) == 1
      [bkm] = definitions.business_knowledge_models

      assert %BusinessKnowledgeModel{} = bkm
      assert bkm.id == "BKM_discount"
      assert bkm.name == "Discount Logic"

      assert %FunctionDefinition{} = bkm.encapsulated_logic
      assert bkm.encapsulated_logic.type == :feel
      assert %DecisionTable{} = bkm.encapsulated_logic.body
      assert bkm.encapsulated_logic.body.hit_policy == :first
      assert length(bkm.encapsulated_logic.body.inputs) == 2
      assert length(bkm.encapsulated_logic.body.outputs) == 1
      assert length(bkm.encapsulated_logic.body.rules) == 3
    end

    test "parses BKM with encapsulatedLogic containing a literalExpression" do
      {:ok, definitions} = Parser.parse(read_fixture("bkm_with_literal_expression.dmn"))

      [bkm] = definitions.business_knowledge_models
      assert bkm.id == "BKM_tax"
      assert bkm.name == "Tax Calculation"

      assert %FunctionDefinition{} = bkm.encapsulated_logic
      assert %LiteralExpression{} = bkm.encapsulated_logic.body
      assert bkm.encapsulated_logic.body.text == "income * taxRate"
    end

    test "parses formalParameter children of encapsulatedLogic" do
      {:ok, definitions} = Parser.parse(read_fixture("bkm_with_decision_table.dmn"))

      [bkm] = definitions.business_knowledge_models
      params = bkm.encapsulated_logic.formal_parameters

      assert length(params) == 2
      [first_param, second_param] = params

      assert %InformationItem{} = first_param
      assert first_param.id == "FP_age"
      assert first_param.name == "customerAge"
      assert first_param.type_ref == "number"

      assert second_param.id == "FP_status"
      assert second_param.name == "memberStatus"
      assert second_param.type_ref == "string"
    end

    test "parses BKM variable" do
      {:ok, definitions} = Parser.parse(read_fixture("bkm_with_decision_table.dmn"))

      [bkm] = definitions.business_knowledge_models
      assert %InformationItem{} = bkm.variable
      assert bkm.variable.id == "var_bkm_discount"
      assert bkm.variable.name == "discountResult"
      assert bkm.variable.type_ref == "number"
    end
  end

  # --- Phase 4: knowledgeRequirement parsing (2B) ----------------------------

  describe "parse/1 — knowledgeRequirement" do
    test "parses knowledgeRequirement on a decision" do
      {:ok, definitions} = Parser.parse(read_fixture("knowledge_requirement_on_decision.dmn"))

      decision = Enum.find(definitions.decisions, &(&1.id == "Decision_main"))
      assert length(decision.knowledge_requirements) == 1

      [kr] = decision.knowledge_requirements
      assert %KnowledgeRequirement{} = kr
      assert kr.id == "kr_helper"
      assert kr.required_knowledge_id == "BKM_helper"
    end

    test "parses knowledgeRequirement on a BKM" do
      {:ok, definitions} = Parser.parse(read_fixture("knowledge_requirement_on_bkm.dmn"))

      bkm_derived = Enum.find(definitions.business_knowledge_models, &(&1.id == "BKM_derived"))
      assert length(bkm_derived.knowledge_requirements) == 1

      [kr] = bkm_derived.knowledge_requirements
      assert %KnowledgeRequirement{} = kr
      assert kr.required_knowledge_id == "BKM_base"

      bkm_base = Enum.find(definitions.business_knowledge_models, &(&1.id == "BKM_base"))
      assert bkm_base.knowledge_requirements == []
    end
  end

  # --- Phase 4: knowledgeSource parsing (2C) ---------------------------------

  describe "parse/1 — knowledgeSource" do
    test "parses knowledgeSource with authorityRequirements" do
      {:ok, definitions} = Parser.parse(read_fixture("knowledge_source_with_authority.dmn"))

      assert length(definitions.knowledge_sources) == 2

      ks_regulation = Enum.find(definitions.knowledge_sources, &(&1.id == "KS_regulation"))
      assert %KnowledgeSource{} = ks_regulation
      assert ks_regulation.name == "Insurance Regulation"
      assert ks_regulation.type == "Policy Document"
      assert length(ks_regulation.authority_requirements) == 1

      [ar] = ks_regulation.authority_requirements
      assert ar.required_input_id == "InputData_amount"

      ks_actuary = Enum.find(definitions.knowledge_sources, &(&1.id == "KS_actuary"))
      assert ks_actuary.name == "Actuarial Standards"
      assert length(ks_actuary.authority_requirements) == 1

      [ar_auth] = ks_actuary.authority_requirements
      assert ar_auth.required_authority_id == "KS_regulation"
    end
  end

  # --- Phase 4: authorityRequirement parsing (2D) ----------------------------

  describe "parse/1 — authorityRequirement" do
    test "parses authorityRequirement with all three href types" do
      {:ok, definitions} = Parser.parse(read_fixture("authority_requirement_all_types.dmn"))

      decision_main = Enum.find(definitions.decisions, &(&1.id == "Decision_main"))
      assert length(decision_main.authority_requirements) == 3

      ar_authority = Enum.find(decision_main.authority_requirements, &(&1.id == "ar_authority_ref"))
      assert %AuthorityRequirement{} = ar_authority
      assert ar_authority.required_authority_id == "KS_policy"
      assert ar_authority.required_decision_id == nil
      assert ar_authority.required_input_id == nil

      ar_decision = Enum.find(decision_main.authority_requirements, &(&1.id == "ar_decision_ref"))
      assert ar_decision.required_decision_id == "Decision_upstream"
      assert ar_decision.required_authority_id == nil

      ar_input = Enum.find(decision_main.authority_requirements, &(&1.id == "ar_input_ref"))
      assert ar_input.required_input_id == "InputData_x"
      assert ar_input.required_authority_id == nil
    end

    test "parses authorityRequirement on a decision (governance edge)" do
      {:ok, definitions} = Parser.parse(read_fixture("knowledge_source_with_authority.dmn"))

      decision = Enum.find(definitions.decisions, &(&1.id == "Decision_claim"))
      assert length(decision.authority_requirements) == 1

      [ar] = decision.authority_requirements
      assert ar.id == "ar_decision_ks"
      assert ar.required_authority_id == "KS_actuary"
    end
  end

  # --- Phase 4: itemDefinition parsing (2E) ----------------------------------

  describe "parse/1 — itemDefinition" do
    test "parses itemDefinition with nested itemComponents" do
      {:ok, definitions} = Parser.parse(read_fixture("item_definitions.dmn"))

      address_def = Enum.find(definitions.item_definitions, &(&1.id == "ItemDef_Address"))
      assert %ItemDefinition{} = address_def
      assert address_def.name == "tAddress"
      assert address_def.type_ref == nil
      assert length(address_def.item_components) == 3

      [street, city, zip] = address_def.item_components
      assert street.name == "street"
      assert street.type_ref == "string"
      assert city.name == "city"
      assert zip.name == "zipCode"
    end

    test "parses itemDefinition with isCollection=true" do
      {:ok, definitions} = Parser.parse(read_fixture("item_definitions.dmn"))

      tags_def = Enum.find(definitions.item_definitions, &(&1.id == "ItemDef_Tags"))
      assert %ItemDefinition{} = tags_def
      assert tags_def.is_collection == true
      assert tags_def.type_ref == "string"
    end

    test "parses itemDefinition with allowedValues" do
      {:ok, definitions} = Parser.parse(read_fixture("item_definitions.dmn"))

      age_def = Enum.find(definitions.item_definitions, &(&1.id == "ItemDef_Age"))
      assert %ItemDefinition{} = age_def
      assert age_def.name == "tAge"
      assert age_def.type_ref == "number"
      assert age_def.allowed_values == "[0..150]"
    end

    test "parses all three item definitions from fixture" do
      {:ok, definitions} = Parser.parse(read_fixture("item_definitions.dmn"))
      assert length(definitions.item_definitions) == 3
    end
  end

  # --- Phase 4: import parsing (2F) ------------------------------------------

  describe "parse/1 — import" do
    test "parses import elements" do
      {:ok, definitions} = Parser.parse(read_fixture("import_element.dmn"))

      assert length(definitions.imports) == 2

      [import_shared, import_helpers] = definitions.imports

      assert %Import{} = import_shared
      assert import_shared.id == "Import_shared"
      assert import_shared.namespace == "https://example.com/dmn/shared-types"
      assert import_shared.location_uri == "shared_types.dmn"
      assert import_shared.import_type == "https://www.omg.org/spec/DMN/20191111/MODEL/"

      assert import_helpers.id == "Import_helpers"
      assert import_helpers.namespace == "https://example.com/dmn/helpers"
      assert import_helpers.location_uri == nil
    end
  end

  # --- Phase 4: decision variable parsing (2G) -------------------------------

  describe "parse/1 — decision variable" do
    test "parses variable child of decision" do
      {:ok, definitions} = Parser.parse(read_fixture("decision_with_variable.dmn"))

      [decision] = definitions.decisions
      assert %InformationItem{} = decision.variable
      assert decision.variable.id == "var_tax"
      assert decision.variable.name == "taxRate"
      assert decision.variable.type_ref == "number"
    end

    test "preserves outputLabel when variable is also present" do
      {:ok, definitions} = Parser.parse(read_fixture("decision_with_variable.dmn"))

      [decision] = definitions.decisions
      assert decision.output_label == "Legacy Label"
      assert decision.variable != nil
    end
  end

  # --- Phase 4: targetNamespace (2J) -----------------------------------------

  describe "parse/1 — targetNamespace" do
    test "reads targetNamespace attribute into definitions.namespace" do
      {:ok, definitions} = Parser.parse(read_fixture("bkm_with_decision_table.dmn"))
      assert definitions.namespace == "https://example.com/dmn/bkm-dt"
    end

    test "falls back to namespace attribute for backward compatibility" do
      {:ok, definitions} = Parser.parse(read_fixture("simple_unique.dmn"))
      assert definitions.namespace == "https://example.com/dmn/discount"
    end
  end

  # --- Phase 4: comprehensive DRD model --------------------------------------

  describe "parse/1 — comprehensive DRD" do
    test "parses complex DRD model with all CL1 element types" do
      {:ok, definitions} = Parser.parse(read_fixture("comprehensive_drd.dmn"))

      assert definitions.id == "definitions_drd"
      assert definitions.namespace == "https://example.com/dmn/comprehensive"

      assert length(definitions.imports) == 1
      assert length(definitions.item_definitions) == 2
      assert length(definitions.input_data) == 2
      assert length(definitions.knowledge_sources) == 1
      assert length(definitions.business_knowledge_models) == 2
      assert length(definitions.decisions) == 3

      bkm_age = Enum.find(definitions.business_knowledge_models, &(&1.id == "BKM_age_discount"))
      assert %DecisionTable{} = bkm_age.encapsulated_logic.body
      assert length(bkm_age.encapsulated_logic.formal_parameters) == 1

      bkm_vol = Enum.find(definitions.business_knowledge_models, &(&1.id == "BKM_volume_discount"))
      assert %LiteralExpression{} = bkm_vol.encapsulated_logic.body

      dec_age = Enum.find(definitions.decisions, &(&1.id == "Decision_age_discount"))
      assert length(dec_age.knowledge_requirements) == 1
      assert length(dec_age.authority_requirements) == 1
      assert dec_age.variable != nil

      dec_final = Enum.find(definitions.decisions, &(&1.id == "Decision_final_discount"))
      assert length(dec_final.information_requirements) == 2
      assert dec_final.variable.name == "finalDiscount"

      ks = hd(definitions.knowledge_sources)
      assert ks.id == "KS_company_policy"
      assert length(ks.authority_requirements) == 1

      item_amount = Enum.find(definitions.item_definitions, &(&1.id == "ItemDef_Amount"))
      assert item_amount.allowed_values != nil

      item_customer = Enum.find(definitions.item_definitions, &(&1.id == "ItemDef_Customer"))
      assert length(item_customer.item_components) == 2
    end
  end

  # --- Phase 4: new Definitions fields default to empty ----------------------

  describe "parse/1 — backward compatibility" do
    test "existing fixtures produce empty Phase 4 lists" do
      {:ok, definitions} = Parser.parse(read_fixture("simple_unique.dmn"))

      assert definitions.business_knowledge_models == []
      assert definitions.knowledge_sources == []
      assert definitions.item_definitions == []
      assert definitions.imports == []
    end

    test "existing decisions have empty Phase 4 fields" do
      {:ok, definitions} = Parser.parse(read_fixture("simple_unique.dmn"))

      [decision] = definitions.decisions
      assert decision.knowledge_requirements == []
      assert decision.authority_requirements == []
      assert decision.variable == nil
    end
  end

  # --- Error paths -----------------------------------------------------------

  describe "parse/1 — error paths" do
    test "rejects non-string input" do
      assert {:error, :dmn_parse_error, %{reason: _}} = Parser.parse(123)
      assert {:error, :dmn_parse_error, %{reason: _}} = Parser.parse(nil)
      assert {:error, :dmn_parse_error, %{reason: _}} = Parser.parse([])
    end

    test "handles malformed XML" do
      assert {:error, :dmn_parse_error, %{reason: _}} = Parser.parse("<definitions><unclosed")
    end

    test "handles empty string" do
      assert {:error, :dmn_parse_error, %{reason: _}} = Parser.parse("")
    end
  end

  # --- Phase 6: CL3 boxed expression parsing ---------------------------------

  describe "parse/1 — boxed context" do
    test "parses boxed context with 3 entries" do
      {:ok, definitions} = Parser.parse(read_fixture("boxed_context_basic.dmn"))
      [decision] = definitions.decisions
      assert %BfwEngine.DMN.Model.BoxedContext{} = decision.expression
      assert length(decision.expression.context_entries) == 3

      [entry1, entry2, entry3] = decision.expression.context_entries
      assert entry1.variable.name == "x"
      assert %LiteralExpression{} = entry1.expression
      assert entry2.variable.name == "y"
      assert entry3.variable == nil
    end

    test "parses nested context" do
      {:ok, definitions} = Parser.parse(read_fixture("boxed_context_nested.dmn"))
      [decision] = definitions.decisions
      assert %BfwEngine.DMN.Model.BoxedContext{} = decision.expression

      [outer_entry1, _outer_entry2] = decision.expression.context_entries
      assert outer_entry1.variable.name == "inner"
      assert %BfwEngine.DMN.Model.BoxedContext{} = outer_entry1.expression
      assert length(outer_entry1.expression.context_entries) == 2
    end
  end

  describe "parse/1 — boxed list" do
    test "parses boxed list with 3 elements" do
      {:ok, definitions} = Parser.parse(read_fixture("boxed_list_basic.dmn"))
      [decision] = definitions.decisions
      assert %BfwEngine.DMN.Model.BoxedList{} = decision.expression
      assert length(decision.expression.elements) == 3
      assert Enum.all?(decision.expression.elements, &match?(%LiteralExpression{}, &1))
    end
  end

  describe "parse/1 — relation" do
    test "parses relation with 2 columns and 2 rows" do
      {:ok, definitions} = Parser.parse(read_fixture("relation_basic.dmn"))
      [decision] = definitions.decisions
      assert %BfwEngine.DMN.Model.Relation{} = decision.expression

      assert length(decision.expression.columns) == 2
      assert length(decision.expression.rows) == 2

      [col1, col2] = decision.expression.columns
      assert col1.name == "Name"
      assert col2.name == "Age"

      [row1, row2] = decision.expression.rows
      assert length(row1) == 2
      assert length(row2) == 2
    end
  end

  describe "parse/1 — boxed conditional" do
    test "parses boxed conditional with if/then/else" do
      {:ok, definitions} = Parser.parse(read_fixture("boxed_conditional_basic.dmn"))
      [decision] = definitions.decisions
      assert %BfwEngine.DMN.Model.BoxedConditional{} = decision.expression
      assert %LiteralExpression{} = decision.expression.if_expression
      assert %LiteralExpression{} = decision.expression.then_expression
      assert %LiteralExpression{} = decision.expression.else_expression
    end
  end

  describe "parse/1 — boxed iterators" do
    test "parses boxed for" do
      {:ok, definitions} = Parser.parse(read_fixture("boxed_iterators.dmn"))
      for_decision = Enum.find(definitions.decisions, &(&1.id == "Decision_for"))
      assert %BfwEngine.DMN.Model.BoxedFor{} = for_decision.expression
      assert for_decision.expression.iterator_variable == "x"
      assert %LiteralExpression{} = for_decision.expression.in_expression
      assert %LiteralExpression{} = for_decision.expression.return_expression
    end

    test "parses boxed every" do
      {:ok, definitions} = Parser.parse(read_fixture("boxed_iterators.dmn"))
      every_decision = Enum.find(definitions.decisions, &(&1.id == "Decision_every"))
      assert %BfwEngine.DMN.Model.BoxedEvery{} = every_decision.expression
      assert every_decision.expression.iterator_variable == "n"
      assert %LiteralExpression{} = every_decision.expression.in_expression
      assert %LiteralExpression{} = every_decision.expression.satisfies_expression
    end

    test "parses boxed some" do
      {:ok, definitions} = Parser.parse(read_fixture("boxed_iterators.dmn"))
      some_decision = Enum.find(definitions.decisions, &(&1.id == "Decision_some"))
      assert %BfwEngine.DMN.Model.BoxedSome{} = some_decision.expression
      assert some_decision.expression.iterator_variable == "n"
    end
  end

  describe "parse/1 — boxed invocation" do
    test "parses boxed invocation with called function and bindings" do
      {:ok, definitions} = Parser.parse(read_fixture("boxed_invocation_basic.dmn"))
      decision = Enum.find(definitions.decisions, &(&1.id == "Decision_apply_tax"))
      assert %BoxedInvocation{} = invocation = decision.expression
      assert invocation.called_function == "Tax Calculation"
      assert length(invocation.bindings) == 2
      [binding_1, binding_2] = invocation.bindings
      assert binding_1.parameter.name == "income"
      assert %LiteralExpression{text: "50000"} = binding_1.expression
      assert binding_2.parameter.name == "rate"
      assert %LiteralExpression{text: "0.2"} = binding_2.expression
    end
  end

  describe "parse/1 — boxed filter" do
    test "parses boxed filter as standalone decision expression" do
      {:ok, definitions} = Parser.parse(read_fixture("boxed_filter_basic.dmn"))
      decision = Enum.find(definitions.decisions, &(&1.id == "Decision_filter"))
      assert %BoxedContext{} = context = decision.expression
      filter_entry = Enum.find(context.context_entries, fn entry ->
        is_nil(entry.variable)
      end)
      assert %BoxedFilter{} = filter = filter_entry.expression
      assert %LiteralExpression{} = filter.in_expression
      assert %LiteralExpression{} = filter.match_expression
    end
  end

  describe "parse/1 — decisionService" do
    test "parses decision service with all child types" do
      {:ok, definitions} = Parser.parse(read_fixture("decision_service_basic.dmn"))

      assert length(definitions.decision_services) == 1
      [service] = definitions.decision_services

      assert %DecisionService{} = service
      assert service.id == "DS_eligibility"
      assert service.name == "Eligibility Service"
      assert service.output_decisions == ["Decision_eligibility"]
      assert service.encapsulated_decisions == ["Decision_risk"]
      assert service.input_data == ["InputData_age", "InputData_income"]
      assert service.input_decisions == []
    end

    test "parses multiple decision services with input decisions" do
      {:ok, definitions} = Parser.parse(read_fixture("decision_service_nested.dmn"))

      assert length(definitions.decision_services) == 2

      fee_service = Enum.find(definitions.decision_services, &(&1.id == "DS_fee_calculation"))
      assert fee_service.name == "Fee Calculation Service"
      assert fee_service.output_decisions == ["Decision_fee"]
      assert fee_service.encapsulated_decisions == ["Decision_adjusted_rate", "Decision_base_rate"]
      assert fee_service.input_data == ["InputData_amount", "InputData_category"]
      assert fee_service.input_decisions == []

      input_service = Enum.find(definitions.decision_services, &(&1.id == "DS_with_input_decisions"))
      assert input_service.output_decisions == ["Decision_fee"]
      assert input_service.encapsulated_decisions == ["Decision_adjusted_rate"]
      assert input_service.input_decisions == ["Decision_base_rate"]
      assert input_service.input_data == ["InputData_amount"]
    end

    test "DMN without decision services has empty list" do
      {:ok, definitions} = Parser.parse(read_fixture("simple_unique.dmn"))
      assert definitions.decision_services == []
    end

    test "inputData elements outside decisionService are still parsed as InputData" do
      {:ok, definitions} = Parser.parse(read_fixture("decision_service_basic.dmn"))

      assert length(definitions.input_data) == 2
      assert Enum.any?(definitions.input_data, &(&1.id == "InputData_age"))
      assert Enum.any?(definitions.input_data, &(&1.id == "InputData_income"))
    end
  end

  describe "parse/1 — functionDefinition as decision expression" do
    test "parses decision with standalone functionDefinition as expression" do
      {:ok, definitions} = Parser.parse(read_fixture("function_definition_as_value.dmn"))

      assert length(definitions.decisions) == 2

      decision = Enum.find(definitions.decisions, &(&1.id == "Decision_function"))
      assert %FunctionDefinition{} = function_definition = decision.expression
      assert function_definition.id == "FD_increment"
      assert function_definition.type == :feel

      assert length(function_definition.formal_parameters) == 1
      [parameter] = function_definition.formal_parameters
      assert parameter.id == "FP_value"
      assert parameter.name == "value"
      assert parameter.type_ref == "number"

      assert %LiteralExpression{text: "value + 1"} = function_definition.body
    end

    test "parses functionDefinition nested inside boxed context entry" do
      {:ok, definitions} = Parser.parse(read_fixture("function_definition_as_value.dmn"))

      decision = Enum.find(definitions.decisions, &(&1.id == "Decision_context_function"))
      assert %BoxedContext{} = context = decision.expression
      assert length(context.context_entries) == 1

      [entry] = context.context_entries
      assert entry.variable.name == "increment"
      assert %FunctionDefinition{} = nested_function = entry.expression
      assert nested_function.id == "FD_context_increment"
      assert length(nested_function.formal_parameters) == 1
      assert hd(nested_function.formal_parameters).name == "value"
      assert %LiteralExpression{text: "value + 1"} = nested_function.body
    end
  end

  describe "parse/1 — nested boxed multi type" do
    test "parses nested boxed context with invocation and literal entries" do
      {:ok, definitions} = Parser.parse(read_fixture("nested_boxed_multi_type.dmn"))

      [business_knowledge_model] = definitions.business_knowledge_models
      assert business_knowledge_model.id == "BKM_values_list"
      assert %FunctionDefinition{} = business_knowledge_model.encapsulated_logic
      assert %BoxedList{} = list = business_knowledge_model.encapsulated_logic.body
      assert length(list.elements) == 3

      [decision] = definitions.decisions
      assert decision.id == "Decision_nested_multi"
      assert [%KnowledgeRequirement{required_knowledge_id: "BKM_values_list"}] =
               decision.knowledge_requirements

      assert %BoxedContext{} = context = decision.expression
      assert length(context.context_entries) == 2

      [items_entry, result_entry] = context.context_entries
      assert items_entry.variable.name == "items"
      assert %BoxedInvocation{} = invocation = items_entry.expression
      assert invocation.called_function == "Values List"
      assert invocation.bindings == []

      assert result_entry.variable == nil
      assert %LiteralExpression{text: "items"} = result_entry.expression
    end
  end

  describe "parse/1 — inline minimal XML (specification-driven)" do
    @inline_definitions_header ~s(<?xml version="1.0" encoding="UTF-8"?>
<definitions xmlns="https://www.omg.org/spec/DMN/20191111/MODEL/"
             id="Definitions_inline"
             name="Inline Test"
             namespace="https://test.example.com/dmn/inline">)

    @inline_definitions_footer "</definitions>"

    defp inline_dmn(body), do: @inline_definitions_header <> body <> @inline_definitions_footer

    test "parses itemDefinition with typeRef, allowedValues, and nested itemComponent" do
      xml =
        inline_dmn("""
          <itemDefinition id="ItemDef_Status" name="tStatus">
            <typeRef>string</typeRef>
            <allowedValues>[\"active\", \"inactive\"]</allowedValues>
          </itemDefinition>
          <itemDefinition id="ItemDef_Person" name="tPerson">
            <itemComponent id="IC_name" name="fullName">
              <typeRef>string</typeRef>
            </itemComponent>
            <itemComponent id="IC_age" name="age">
              <typeRef>number</typeRef>
            </itemComponent>
          </itemDefinition>
        """)

      {:ok, definitions} = Parser.parse(xml)

      status_definition = Enum.find(definitions.item_definitions, &(&1.id == "ItemDef_Status"))
      assert status_definition.type_ref == "string"
      assert status_definition.allowed_values == "[\"active\", \"inactive\"]"

      person_definition = Enum.find(definitions.item_definitions, &(&1.id == "ItemDef_Person"))
      assert person_definition.type_ref == nil
      assert length(person_definition.item_components) == 2
      [name_component, age_component] = person_definition.item_components
      assert name_component.name == "fullName"
      assert age_component.type_ref == "number"
    end

    test "parses import with namespace, importType, and locationURI" do
      xml =
        inline_dmn("""
          <import id="Import_helpers"
                  namespace="https://test.example.com/helpers"
                  importType="https://www.omg.org/spec/DMN/20191111/MODEL/"
                  locationURI="helpers.dmn"/>
        """)

      {:ok, definitions} = Parser.parse(xml)
      assert [import_element] = definitions.imports
      assert import_element.namespace == "https://test.example.com/helpers"
      assert import_element.import_type == "https://www.omg.org/spec/DMN/20191111/MODEL/"
      assert import_element.location_uri == "helpers.dmn"
    end

    test "parses decisionService children with href attributes" do
      xml =
        inline_dmn("""
          <inputData id="InputData_score" name="score"/>
          <decision id="Decision_inner" name="Inner">
            <literalExpression><text>score * 2</text></literalExpression>
          </decision>
          <decision id="Decision_outer" name="Outer">
            <literalExpression><text>inner + 1</text></literalExpression>
          </decision>
          <decisionService id="DS_scoring" name="Scoring Service">
            <outputDecision href="#Decision_outer"/>
            <encapsulatedDecision href="#Decision_inner"/>
            <inputDecision href="#Decision_inner"/>
            <inputData href="#InputData_score"/>
          </decisionService>
        """)

      {:ok, definitions} = Parser.parse(xml)
      [service] = definitions.decision_services
      assert service.output_decisions == ["Decision_outer"]
      assert service.encapsulated_decisions == ["Decision_inner"]
      assert service.input_decisions == ["Decision_inner"]
      assert service.input_data == ["InputData_score"]
    end

    test "parses BKM with encapsulatedLogic, formalParameter, and BKM knowledgeRequirement" do
      xml =
        inline_dmn("""
          <businessKnowledgeModel id="BKM_base" name="Base">
            <encapsulatedLogic>
              <literalExpression><text>1</text></literalExpression>
            </encapsulatedLogic>
          </businessKnowledgeModel>
          <businessKnowledgeModel id="BKM_derived" name="Derived">
            <knowledgeRequirement>
              <requiredKnowledge href="#BKM_base"/>
            </knowledgeRequirement>
            <encapsulatedLogic>
              <formalParameter id="FP_value" name="value" typeRef="number"/>
              <literalExpression><text>value + base</text></literalExpression>
            </encapsulatedLogic>
          </businessKnowledgeModel>
        """)

      {:ok, definitions} = Parser.parse(xml)
      derived_bkm = Enum.find(definitions.business_knowledge_models, &(&1.id == "BKM_derived"))
      assert [%KnowledgeRequirement{required_knowledge_id: "BKM_base"}] = derived_bkm.knowledge_requirements
      assert [%InformationItem{name: "value"}] = derived_bkm.encapsulated_logic.formal_parameters
    end

    test "parses authorityRequirement with requiredAuthority, requiredDecision, and requiredInput" do
      xml =
        inline_dmn("""
          <knowledgeSource id="KS_policy" name="Policy"/>
          <inputData id="InputData_amount" name="amount"/>
          <decision id="Decision_upstream" name="Upstream">
            <literalExpression><text>1</text></literalExpression>
          </decision>
          <decision id="Decision_main" name="Main">
            <authorityRequirement id="AR_authority">
              <requiredAuthority href="#KS_policy"/>
            </authorityRequirement>
            <authorityRequirement id="AR_decision">
              <requiredDecision href="#Decision_upstream"/>
            </authorityRequirement>
            <authorityRequirement id="AR_input">
              <requiredInput href="#InputData_amount"/>
            </authorityRequirement>
            <literalExpression><text>1</text></literalExpression>
          </decision>
        """)

      {:ok, definitions} = Parser.parse(xml)
      decision = Enum.find(definitions.decisions, &(&1.id == "Decision_main"))
      assert length(decision.authority_requirements) == 3

      authority_ref = Enum.find(decision.authority_requirements, &(&1.id == "AR_authority"))
      assert authority_ref.required_authority_id == "KS_policy"

      decision_ref = Enum.find(decision.authority_requirements, &(&1.id == "AR_decision"))
      assert decision_ref.required_decision_id == "Decision_upstream"

      input_ref = Enum.find(decision.authority_requirements, &(&1.id == "AR_input"))
      assert input_ref.required_input_id == "InputData_amount"
    end

    test "parses boxed expressions: context, invocation, list, relation, conditional, filter, iterators, functionDefinition" do
      xml =
        inline_dmn("""
          <businessKnowledgeModel id="BKM_double" name="Double">
            <encapsulatedLogic>
              <formalParameter id="FP_x" name="x" typeRef="number"/>
              <literalExpression><text>x * 2</text></literalExpression>
            </encapsulatedLogic>
          </businessKnowledgeModel>
          <decision id="Decision_context" name="Context">
            <context>
              <contextEntry><literalExpression><text>1</text></literalExpression></contextEntry>
            </context>
          </decision>
          <decision id="Decision_list" name="List">
            <list><literalExpression><text>1</text></literalExpression></list>
          </decision>
          <decision id="Decision_relation" name="Relation">
            <relation>
              <column id="Col_a" name="a" typeRef="number"/>
              <row><literalExpression><text>1</text></literalExpression></row>
            </relation>
          </decision>
          <decision id="Decision_conditional" name="Conditional">
            <conditional>
              <if><literalExpression><text>true</text></literalExpression></if>
              <then><literalExpression><text>1</text></literalExpression></then>
              <else><literalExpression><text>0</text></literalExpression></else>
            </conditional>
          </decision>
          <decision id="Decision_filter" name="Filter">
            <filter>
              <in><literalExpression><text>[1,2,3]</text></literalExpression></in>
              <match><literalExpression><text>item > 1</text></literalExpression></match>
            </filter>
          </decision>
          <decision id="Decision_for" name="For">
            <for iteratorVariable="item">
              <in><literalExpression><text>[1,2]</text></literalExpression></in>
              <return><literalExpression><text>item</text></literalExpression></return>
            </for>
          </decision>
          <decision id="Decision_every" name="Every">
            <every iteratorVariable="item">
              <in><literalExpression><text>[1,2]</text></literalExpression></in>
              <satisfies><literalExpression><text>item > 0</text></literalExpression></satisfies>
            </every>
          </decision>
          <decision id="Decision_some" name="Some">
            <some iteratorVariable="item">
              <in><literalExpression><text>[1,2]</text></literalExpression></in>
              <satisfies><literalExpression><text>item > 1</text></literalExpression></satisfies>
            </some>
          </decision>
          <decision id="Decision_invocation" name="Invocation">
            <invocation>
              <literalExpression><text>Double</text></literalExpression>
              <binding name="x"><literalExpression><text>5</text></literalExpression></binding>
            </invocation>
          </decision>
          <decision id="Decision_function" name="Function">
            <functionDefinition id="FD_inc" kind="FEEL">
              <formalParameter id="FP_n" name="n" typeRef="number"/>
              <literalExpression><text>n + 1</text></literalExpression>
            </functionDefinition>
          </decision>
        """)

      {:ok, definitions} = Parser.parse(xml)

      assert %BoxedContext{} = Enum.find(definitions.decisions, &(&1.id == "Decision_context")).expression
      assert %BoxedList{} = Enum.find(definitions.decisions, &(&1.id == "Decision_list")).expression
      assert %Relation{} = Enum.find(definitions.decisions, &(&1.id == "Decision_relation")).expression
      assert %BoxedConditional{} = Enum.find(definitions.decisions, &(&1.id == "Decision_conditional")).expression
      assert %BoxedFilter{} = Enum.find(definitions.decisions, &(&1.id == "Decision_filter")).expression
      assert %BoxedFor{} = Enum.find(definitions.decisions, &(&1.id == "Decision_for")).expression
      assert %BoxedEvery{} = Enum.find(definitions.decisions, &(&1.id == "Decision_every")).expression
      assert %BoxedSome{} = Enum.find(definitions.decisions, &(&1.id == "Decision_some")).expression
      assert %BoxedInvocation{} = Enum.find(definitions.decisions, &(&1.id == "Decision_invocation")).expression
      assert %FunctionDefinition{} = Enum.find(definitions.decisions, &(&1.id == "Decision_function")).expression
    end

    test "returns parse error for structurally invalid XML" do
      assert {:error, :dmn_parse_error, %{reason: reason}} =
               Parser.parse(inline_dmn("<decision><unclosed"))

      assert is_binary(reason)
    end
  end

  describe "parse/1 — DMNDI elements are ignored" do
    test "DMNDI elements in XML are silently skipped — semantic model is parsed correctly" do
      {:ok, definitions} = Parser.parse(read_fixture("with_dmndi.dmn"))

      assert definitions.id == "definitions_dmndi"
      assert definitions.name == "DMNDI Test"
      assert length(definitions.decisions) == 1
      assert length(definitions.input_data) == 1

      [decision] = definitions.decisions
      assert decision.id == "Decision_result"
      assert decision.name == "Result"
      refute Map.has_key?(definitions, :dmndi)
    end
  end
end
