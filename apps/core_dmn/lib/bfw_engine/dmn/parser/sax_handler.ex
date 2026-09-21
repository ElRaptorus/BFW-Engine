defmodule BfwEngine.DMN.Parser.SaxHandler do
  @moduledoc """
  Saxy callback module that builds `BfwEngine.DMN.Model.*` structs
  from SAX events.

  Supports all DMN CL3 boxed expression types with arbitrary nesting
  via a generic `attach_completed_expression/2` mechanism. Each
  completed expression body is attached to its parent container by
  inspecting the handler stack.
  """

  @behaviour Saxy.Handler

  alias BfwEngine.DMN.Model.AuthorityRequirement
  alias BfwEngine.DMN.Model.BusinessKnowledgeModel
  alias BfwEngine.DMN.Model.ContextEntry
  alias BfwEngine.DMN.Model.Decision
  alias BfwEngine.DMN.Model.DecisionService
  alias BfwEngine.DMN.Model.DecisionTable
  alias BfwEngine.DMN.Model.Definitions
  alias BfwEngine.DMN.Model.FunctionDefinition
  alias BfwEngine.DMN.Model.Import
  alias BfwEngine.DMN.Model.InformationItem
  alias BfwEngine.DMN.Model.InformationRequirement
  alias BfwEngine.DMN.Model.Input
  alias BfwEngine.DMN.Model.InputData
  alias BfwEngine.DMN.Model.InputEntry
  alias BfwEngine.DMN.Model.ItemDefinition
  alias BfwEngine.DMN.Model.KnowledgeRequirement
  alias BfwEngine.DMN.Model.KnowledgeSource
  alias BfwEngine.DMN.Model.LiteralExpression
  alias BfwEngine.DMN.Model.Output
  alias BfwEngine.DMN.Model.OutputEntry
  alias BfwEngine.DMN.Model.Rule
  alias BfwEngine.DMN.Parser.SaxHandler.BoxedExpressions

  @hit_policy_map %{
    "UNIQUE" => :unique, "U" => :unique,
    "FIRST" => :first, "F" => :first,
    "ANY" => :any, "A" => :any,
    "COLLECT" => :collect, "C" => :collect,
    "RULE ORDER" => :rule_order, "R" => :rule_order,
    "OUTPUT ORDER" => :output_order, "O" => :output_order,
    "PRIORITY" => :priority, "P" => :priority
  }

  @aggregation_map %{
    "SUM" => :sum,
    "MIN" => :min,
    "MAX" => :max,
    "COUNT" => :count
  }

  @orientation_map %{
    "Rule-as-Row" => :rule_as_row,
    "Rule-as-Column" => :rule_as_column,
    "CrossTable" => :cross_table
  }

  @expression_parent_tags [
    :decision, :encapsulated_logic, :function_definition, :context_entry, :binding,
    :invocation, :list, :relation_row,
    :conditional_if, :conditional_then, :conditional_else,
    :filter_in, :filter_match,
    :for_in, :for_return,
    :every_in, :every_satisfies,
    :some_in, :some_satisfies
  ]

  @doc false
  def initial_state(raw_xml) do
    %{
      raw_xml: raw_xml,
      definitions_id: nil,
      definitions_name: nil,
      definitions_namespace: nil,
      decisions: [],
      input_data_list: [],
      business_knowledge_models: [],
      knowledge_sources: [],
      decision_services: [],
      item_definitions: [],
      imports: [],
      # CL1 current-element fields
      current_decision: nil,
      current_decision_table: nil,
      current_input: nil,
      current_output: nil,
      current_rule: nil,
      current_literal_expression: nil,
      current_information_requirement: nil,
      current_business_knowledge_model: nil,
      current_function_definition: nil,
      current_knowledge_requirement: nil,
      current_authority_requirement: nil,
      current_knowledge_source: nil,
      current_decision_service: nil,
      current_item_definition: nil,
      item_definition_stack: [],
      # CL3 boxed expression fields
      current_context: nil,
      current_context_entry: nil,
      context_stack: [],
      context_entry_stack: [],
      current_invocation: nil,
      current_binding: nil,
      invocation_stack: [],
      current_list: nil,
      list_stack: [],
      current_relation: nil,
      current_relation_row: nil,
      relation_stack: [],
      current_conditional: nil,
      conditional_stack: [],
      current_filter: nil,
      filter_stack: [],
      current_for: nil,
      for_stack: [],
      current_every: nil,
      every_stack: [],
      current_some: nil,
      some_stack: [],
      # General
      stack: [],
      text_buffer: ""
    }
  end

  @doc false
  def finalize(state) do
    decisions =
      state.decisions
      |> Enum.reverse()
      |> Enum.map(&finalize_decision/1)

    business_knowledge_models =
      state.business_knowledge_models
      |> Enum.reverse()
      |> Enum.map(&finalize_bkm/1)

    %Definitions{
      id: state.definitions_id,
      name: state.definitions_name,
      namespace: state.definitions_namespace,
      decisions: decisions,
      input_data: Enum.reverse(state.input_data_list),
      business_knowledge_models: business_knowledge_models,
      knowledge_sources: Enum.reverse(state.knowledge_sources),
      decision_services: Enum.reverse(state.decision_services),
      item_definitions: Enum.reverse(state.item_definitions),
      imports: Enum.reverse(state.imports),
      raw_xml: state.raw_xml
    }
  end

  # --- Saxy callbacks --------------------------------------------------------

  @impl Saxy.Handler
  def handle_event(:start_document, _prolog, state), do: {:ok, state}

  @impl Saxy.Handler
  def handle_event(:end_document, _data, state), do: {:ok, state}

  @impl Saxy.Handler
  def handle_event(:characters, chars, state) do
    {:ok, %{state | text_buffer: state.text_buffer <> chars}}
  end

  @impl Saxy.Handler
  def handle_event(:start_element, {raw_name, attributes}, state) do
    name = local_name(raw_name)
    attrs = attribute_map(attributes)
    state = %{state | text_buffer: ""}
    handle_start(name, attrs, state)
  end

  @impl Saxy.Handler
  def handle_event(:end_element, raw_name, state) do
    name = local_name(raw_name)
    handle_end(name, state)
  end

  # --- Start element handlers ------------------------------------------------

  defp handle_start("definitions", attrs, state) do
    namespace = attrs["targetNamespace"] || attrs["namespace"]

    {:ok,
     %{
       state
       | definitions_id: attrs["id"],
         definitions_name: attrs["name"],
         definitions_namespace: namespace,
         stack: [:definitions | state.stack]
     }}
  end

  defp handle_start("decision", attrs, state) do
    decision = %Decision{
      id: attrs["id"],
      name: attrs["name"],
      output_label: attrs["outputLabel"]
    }

    {:ok, %{state | current_decision: decision, stack: [:decision | state.stack]}}
  end

  defp handle_start("decisionTable", attrs, state) do
    hit_policy_raw = attrs["hitPolicy"] || "UNIQUE"
    aggregation_raw = attrs["aggregation"]
    orientation_raw = attrs["preferredOrientation"]

    table = %DecisionTable{
      id: attrs["id"],
      hit_policy: Map.get(@hit_policy_map, hit_policy_raw, :unique),
      aggregation: Map.get(@aggregation_map, aggregation_raw),
      preferred_orientation:
        Map.get(@orientation_map, orientation_raw, :rule_as_row)
    }

    {:ok, %{state | current_decision_table: table, stack: [:decision_table | state.stack]}}
  end

  defp handle_start("input", attrs, state) when hd(state.stack) == :decision_table do
    input = %Input{id: attrs["id"], label: attrs["label"]}
    {:ok, %{state | current_input: input, stack: [:input | state.stack]}}
  end

  defp handle_start("inputExpression", attrs, state) when hd(state.stack) == :input do
    %Input{} = current_input = state.current_input
    current_input = %{current_input | type_ref: attrs["typeRef"]}
    {:ok, %{state | current_input: current_input, stack: [:input_expression | state.stack]}}
  end

  defp handle_start("inputValues", _attrs, state) when hd(state.stack) == :input do
    {:ok, %{state | stack: [:input_values | state.stack]}}
  end

  defp handle_start("output", attrs, state) when hd(state.stack) == :decision_table do
    output = %Output{
      id: attrs["id"],
      label: attrs["label"],
      name: attrs["name"],
      type_ref: attrs["typeRef"]
    }

    {:ok, %{state | current_output: output, stack: [:output | state.stack]}}
  end

  defp handle_start("outputValues", _attrs, state) when hd(state.stack) == :output do
    {:ok, %{state | stack: [:output_values | state.stack]}}
  end

  defp handle_start("defaultOutputEntry", _attrs, state) when hd(state.stack) == :output do
    {:ok, %{state | stack: [:default_output_entry | state.stack]}}
  end

  defp handle_start("rule", attrs, state) when hd(state.stack) == :decision_table do
    rule = %Rule{id: attrs["id"], description: attrs["description"]}
    {:ok, %{state | current_rule: rule, stack: [:rule | state.stack]}}
  end

  defp handle_start("inputEntry", attrs, state) when hd(state.stack) == :rule do
    {:ok, %{state | stack: [{:input_entry, attrs["id"]} | state.stack]}}
  end

  defp handle_start("outputEntry", attrs, state) when hd(state.stack) == :rule do
    {:ok, %{state | stack: [{:output_entry, attrs["id"]} | state.stack]}}
  end

  defp handle_start("description", _attrs, state) when hd(state.stack) == :rule do
    {:ok, %{state | stack: [:rule_description | state.stack]}}
  end

  defp handle_start("annotationEntry", _attrs, state) when hd(state.stack) == :rule do
    {:ok, %{state | stack: [:annotation_entry | state.stack]}}
  end

  # literalExpression — can appear as child of any expression parent
  defp handle_start("literalExpression", attrs, state)
       when hd(state.stack) in @expression_parent_tags do
    literal = %LiteralExpression{
      id: attrs["id"],
      text: "",
      type_ref: attrs["typeRef"],
      expression_language: attrs["expressionLanguage"]
    }

    {:ok,
     %{state | current_literal_expression: literal, stack: [:literal_expression | state.stack]}}
  end

  defp handle_start("text", _attrs, state) do
    {:ok, %{state | stack: [:text | state.stack]}}
  end

  defp handle_start("inputData", attrs, state) when hd(state.stack) != :decision_service do
    input_data = %InputData{
      id: attrs["id"],
      name: attrs["name"] || attrs["id"]
    }

    {:ok,
     %{
       state
       | stack: [:input_data | state.stack],
         input_data_list: [input_data | state.input_data_list]
     }}
  end

  # --- informationRequirement (on decision) ----------------------------------

  defp handle_start("informationRequirement", attrs, state) when hd(state.stack) == :decision do
    requirement = %InformationRequirement{id: attrs["id"]}

    {:ok,
     %{
       state
       | current_information_requirement: requirement,
         stack: [:information_requirement | state.stack]
     }}
  end

  defp handle_start("requiredDecision", attrs, state)
       when hd(state.stack) == :information_requirement do
    href = extract_href(attrs["href"])
    %InformationRequirement{} = requirement = state.current_information_requirement
    requirement = %{requirement | required_decision_id: href}
    {:ok, %{state | current_information_requirement: requirement}}
  end

  defp handle_start("requiredInput", attrs, state)
       when hd(state.stack) == :information_requirement do
    href = extract_href(attrs["href"])
    %InformationRequirement{} = requirement = state.current_information_requirement
    requirement = %{requirement | required_input_id: href}
    {:ok, %{state | current_information_requirement: requirement}}
  end

  # --- variable (on inputData, decision, BKM, or contextEntry) ---------------

  defp handle_start("variable", attrs, state) when hd(state.stack) == :input_data do
    type_ref = attrs["typeRef"]
    %InputData{} = input_data = hd(state.input_data_list)
    updated = %{input_data | type_ref: type_ref}
    {:ok, %{state | input_data_list: [updated | tl(state.input_data_list)]}}
  end

  defp handle_start("variable", attrs, state) when hd(state.stack) == :decision do
    variable = %InformationItem{
      id: attrs["id"],
      name: attrs["name"] || "",
      type_ref: attrs["typeRef"]
    }

    %Decision{} = current_decision = state.current_decision
    decision = %{current_decision | variable: variable}
    {:ok, %{state | current_decision: decision}}
  end

  defp handle_start("variable", attrs, state)
       when hd(state.stack) == :business_knowledge_model do
    variable = %InformationItem{
      id: attrs["id"],
      name: attrs["name"] || "",
      type_ref: attrs["typeRef"]
    }

    %BusinessKnowledgeModel{} = current_business_knowledge_model = state.current_business_knowledge_model
    updated_business_knowledge_model = %{current_business_knowledge_model | variable: variable}
    {:ok, %{state | current_business_knowledge_model: updated_business_knowledge_model}}
  end

  defp handle_start("variable", attrs, state) when hd(state.stack) == :context_entry do
    variable = %InformationItem{
      id: attrs["id"],
      name: attrs["name"] || "",
      type_ref: attrs["typeRef"]
    }

    %ContextEntry{} = entry = state.current_context_entry
    {:ok, %{state | current_context_entry: %{entry | variable: variable}}}
  end

  # --- businessKnowledgeModel (2A) -------------------------------------------

  defp handle_start("businessKnowledgeModel", attrs, state) do
    business_knowledge_model = %BusinessKnowledgeModel{
      id: attrs["id"],
      name: attrs["name"]
    }

    {:ok,
     %{state | current_business_knowledge_model: business_knowledge_model, stack: [:business_knowledge_model | state.stack]}}
  end

  defp handle_start("encapsulatedLogic", attrs, state)
       when hd(state.stack) == :business_knowledge_model do
    {:ok, begin_function_definition(state, attrs, :encapsulated_logic)}
  end

  defp handle_start("functionDefinition", attrs, state)
       when hd(state.stack) in [:decision, :context_entry] do
    {:ok, begin_function_definition(state, attrs, :function_definition)}
  end

  defp handle_start("formalParameter", attrs, state)
       when hd(state.stack) in [:encapsulated_logic, :function_definition] do
    parameter = %InformationItem{
      id: attrs["id"],
      name: attrs["name"] || "",
      type_ref: attrs["typeRef"]
    }

    %FunctionDefinition{} = existing_function_definition = state.current_function_definition

    function_definition = %{
      existing_function_definition
      | formal_parameters: [parameter | existing_function_definition.formal_parameters]
    }

    {:ok, %{state | current_function_definition: function_definition}}
  end

  # --- CL3: Boxed expressions (delegated to BoxedExpressions submodule) ------

  defp handle_start("context", attrs, state) when hd(state.stack) in @expression_parent_tags,
    do: BoxedExpressions.start_context(attrs, state)

  defp handle_start("contextEntry", attrs, state) when hd(state.stack) == :context,
    do: BoxedExpressions.start_context_entry(attrs, state)

  defp handle_start("invocation", attrs, state) when hd(state.stack) in @expression_parent_tags,
    do: BoxedExpressions.start_invocation(attrs, state)

  defp handle_start("binding", attrs, state) when hd(state.stack) == :invocation,
    do: BoxedExpressions.start_binding(attrs, state)

  defp handle_start("parameter", attrs, state) when hd(state.stack) == :binding,
    do: BoxedExpressions.start_parameter(attrs, state)

  defp handle_start("list", attrs, state) when hd(state.stack) in @expression_parent_tags,
    do: BoxedExpressions.start_list(attrs, state)

  defp handle_start("relation", attrs, state) when hd(state.stack) in @expression_parent_tags,
    do: BoxedExpressions.start_relation(attrs, state)

  defp handle_start("column", attrs, state) when hd(state.stack) == :relation,
    do: BoxedExpressions.start_column(attrs, state)

  defp handle_start("row", attrs, state) when hd(state.stack) == :relation,
    do: BoxedExpressions.start_row(attrs, state)

  defp handle_start("conditional", attrs, state) when hd(state.stack) in @expression_parent_tags,
    do: BoxedExpressions.start_conditional(attrs, state)

  defp handle_start("if", _attrs, state) when hd(state.stack) == :conditional,
    do: BoxedExpressions.start_if(state)

  defp handle_start("then", _attrs, state) when hd(state.stack) == :conditional,
    do: BoxedExpressions.start_then(state)

  defp handle_start("else", _attrs, state) when hd(state.stack) == :conditional,
    do: BoxedExpressions.start_else(state)

  defp handle_start("filter", attrs, state) when hd(state.stack) in @expression_parent_tags,
    do: BoxedExpressions.start_filter(attrs, state)

  defp handle_start("in", _attrs, state) when hd(state.stack) == :filter,
    do: BoxedExpressions.start_filter_in(state)

  defp handle_start("match", _attrs, state) when hd(state.stack) == :filter,
    do: BoxedExpressions.start_filter_match(state)

  defp handle_start("for", attrs, state) when hd(state.stack) in @expression_parent_tags,
    do: BoxedExpressions.start_for(attrs, state)

  defp handle_start("in", _attrs, state) when hd(state.stack) == :for,
    do: BoxedExpressions.start_for_in(state)

  defp handle_start("return", _attrs, state) when hd(state.stack) == :for,
    do: BoxedExpressions.start_for_return(state)

  defp handle_start("every", attrs, state) when hd(state.stack) in @expression_parent_tags,
    do: BoxedExpressions.start_every(attrs, state)

  defp handle_start("in", _attrs, state) when hd(state.stack) == :every,
    do: BoxedExpressions.start_every_in(state)

  defp handle_start("satisfies", _attrs, state) when hd(state.stack) == :every,
    do: BoxedExpressions.start_every_satisfies(state)

  defp handle_start("some", attrs, state) when hd(state.stack) in @expression_parent_tags,
    do: BoxedExpressions.start_some(attrs, state)

  defp handle_start("in", _attrs, state) when hd(state.stack) == :some,
    do: BoxedExpressions.start_some_in(state)

  defp handle_start("satisfies", _attrs, state) when hd(state.stack) == :some,
    do: BoxedExpressions.start_some_satisfies(state)

  # --- knowledgeRequirement (2B) — on decision or BKM ------------------------

  defp handle_start("knowledgeRequirement", attrs, state)
       when hd(state.stack) in [:decision, :business_knowledge_model] do
    requirement = %KnowledgeRequirement{
      id: attrs["id"],
      required_knowledge_id: ""
    }

    {:ok,
     %{
       state
       | current_knowledge_requirement: requirement,
         stack: [:knowledge_requirement | state.stack]
     }}
  end

  defp handle_start("requiredKnowledge", attrs, state)
       when hd(state.stack) == :knowledge_requirement do
    href = extract_href(attrs["href"])
    %KnowledgeRequirement{} = requirement = state.current_knowledge_requirement
    requirement = %{requirement | required_knowledge_id: href || ""}
    {:ok, %{state | current_knowledge_requirement: requirement}}
  end

  # --- knowledgeSource (2C) --------------------------------------------------

  defp handle_start("knowledgeSource", attrs, state) do
    knowledge_source = %KnowledgeSource{
      id: attrs["id"],
      name: attrs["name"],
      type: attrs["type"]
    }

    {:ok,
     %{
       state
       | current_knowledge_source: knowledge_source,
         stack: [:knowledge_source | state.stack]
     }}
  end

  # --- decisionService --------------------------------------------------------

  defp handle_start("decisionService", attrs, state) do
    service = %DecisionService{
      id: attrs["id"],
      name: attrs["name"]
    }

    {:ok,
     %{
       state
       | current_decision_service: service,
         stack: [:decision_service | state.stack]
     }}
  end

  defp handle_start("outputDecision", attrs, state)
       when hd(state.stack) == :decision_service do
    href = extract_href(attrs["href"])
    service = state.current_decision_service
    service = %{service | output_decisions: [href | service.output_decisions]}
    {:ok, %{state | current_decision_service: service, stack: [:output_decision | state.stack]}}
  end

  defp handle_start("encapsulatedDecision", attrs, state)
       when hd(state.stack) == :decision_service do
    href = extract_href(attrs["href"])
    service = state.current_decision_service
    service = %{service | encapsulated_decisions: [href | service.encapsulated_decisions]}
    {:ok, %{state | current_decision_service: service, stack: [:encapsulated_decision | state.stack]}}
  end

  defp handle_start("inputDecision", attrs, state)
       when hd(state.stack) == :decision_service do
    href = extract_href(attrs["href"])
    service = state.current_decision_service
    service = %{service | input_decisions: [href | service.input_decisions]}
    {:ok, %{state | current_decision_service: service, stack: [:input_decision | state.stack]}}
  end

  defp handle_start("inputData", attrs, state)
       when hd(state.stack) == :decision_service do
    href = extract_href(attrs["href"])
    service = state.current_decision_service
    service = %{service | input_data: [href | service.input_data]}
    {:ok, %{state | current_decision_service: service, stack: [:service_input_data | state.stack]}}
  end

  # --- authorityRequirement (2D) — on decision, BKM, or knowledgeSource ------

  defp handle_start("authorityRequirement", attrs, state)
       when hd(state.stack) in [:decision, :business_knowledge_model, :knowledge_source] do
    requirement = %AuthorityRequirement{id: attrs["id"]}

    {:ok,
     %{
       state
       | current_authority_requirement: requirement,
         stack: [:authority_requirement | state.stack]
     }}
  end

  defp handle_start("requiredAuthority", attrs, state)
       when hd(state.stack) == :authority_requirement do
    href = extract_href(attrs["href"])
    %AuthorityRequirement{} = requirement = state.current_authority_requirement
    requirement = %{requirement | required_authority_id: href}
    {:ok, %{state | current_authority_requirement: requirement}}
  end

  defp handle_start("requiredDecision", attrs, state)
       when hd(state.stack) == :authority_requirement do
    href = extract_href(attrs["href"])
    %AuthorityRequirement{} = requirement = state.current_authority_requirement
    requirement = %{requirement | required_decision_id: href}
    {:ok, %{state | current_authority_requirement: requirement}}
  end

  defp handle_start("requiredInput", attrs, state)
       when hd(state.stack) == :authority_requirement do
    href = extract_href(attrs["href"])
    %AuthorityRequirement{} = requirement = state.current_authority_requirement
    requirement = %{requirement | required_input_id: href}
    {:ok, %{state | current_authority_requirement: requirement}}
  end

  # --- itemDefinition (2E) ---------------------------------------------------

  defp handle_start("itemDefinition", attrs, state) do
    is_collection = attrs["isCollection"] == "true"

    item_def = %ItemDefinition{
      id: attrs["id"] || "",
      name: attrs["name"] || "",
      is_collection: is_collection
    }

    nested_stack =
      if state.current_item_definition do
        [state.current_item_definition | state.item_definition_stack]
      else
        state.item_definition_stack
      end

    {:ok,
     %{
       state
       | current_item_definition: item_def,
         item_definition_stack: nested_stack,
         stack: [:item_definition | state.stack]
     }}
  end

  defp handle_start("itemComponent", attrs, state) when hd(state.stack) == :item_definition do
    is_collection = attrs["isCollection"] == "true"

    component = %ItemDefinition{
      id: attrs["id"] || "",
      name: attrs["name"] || "",
      is_collection: is_collection
    }

    nested_stack = [state.current_item_definition | state.item_definition_stack]

    {:ok,
     %{
       state
       | current_item_definition: component,
         item_definition_stack: nested_stack,
         stack: [:item_component | state.stack]
     }}
  end

  defp handle_start("typeRef", _attrs, state)
       when hd(state.stack) in [:item_definition, :item_component] do
    {:ok, %{state | stack: [:type_ref | state.stack]}}
  end

  defp handle_start("allowedValues", _attrs, state)
       when hd(state.stack) in [:item_definition, :item_component] do
    {:ok, %{state | stack: [:allowed_values | state.stack]}}
  end

  # --- import (2F) -----------------------------------------------------------

  defp handle_start("import", attrs, state) do
    dmn_import = %Import{
      id: attrs["id"],
      namespace: attrs["namespace"] || "",
      location_uri: attrs["locationURI"],
      import_type: attrs["importType"] || ""
    }

    {:ok,
     %{state | imports: [dmn_import | state.imports], stack: [:import | state.stack]}}
  end

  # --- Catch-all -------------------------------------------------------------

  defp handle_start(_name, _attrs, state), do: {:ok, state}

  # === End element handlers ==================================================

  defp handle_end("definitions", state) do
    {:ok, %{state | stack: tl(state.stack)}}
  end

  defp handle_end("decision", state) do
    decision = state.current_decision

    {:ok,
     %{
       state
       | decisions: [decision | state.decisions],
         current_decision: nil,
         stack: tl(state.stack)
     }}
  end

  defp handle_end("decisionTable", state) do
    table = finalize_decision_table(state.current_decision_table)
    state = attach_completed_expression(%{state | current_decision_table: nil}, table)
    {:ok, %{state | stack: tl(state.stack)}}
  end

  defp handle_end("input", state) do
    input = state.current_input
    %DecisionTable{} = current_table = state.current_decision_table
    table = %{current_table | inputs: [input | current_table.inputs]}
    {:ok, %{state | current_decision_table: table, current_input: nil, stack: tl(state.stack)}}
  end

  defp handle_end("inputExpression", state) do
    text = String.trim(state.text_buffer)
    %Input{} = current_input = state.current_input
    input = %{current_input | input_expression: if(text == "", do: nil, else: text)}
    {:ok, %{state | current_input: input, stack: tl(state.stack), text_buffer: ""}}
  end

  defp handle_end("inputValues", state) do
    text = String.trim(state.text_buffer)
    %Input{} = current_input = state.current_input
    input = %{current_input | input_values: if(text == "", do: nil, else: text)}
    {:ok, %{state | current_input: input, stack: tl(state.stack), text_buffer: ""}}
  end

  defp handle_end("output", state) do
    output = state.current_output
    %DecisionTable{} = current_table = state.current_decision_table
    table = %{current_table | outputs: [output | current_table.outputs]}
    {:ok, %{state | current_decision_table: table, current_output: nil, stack: tl(state.stack)}}
  end

  defp handle_end("outputValues", state) do
    text = String.trim(state.text_buffer)
    %Output{} = current_output = state.current_output
    output = %{current_output | output_values: if(text == "", do: nil, else: text)}
    {:ok, %{state | current_output: output, stack: tl(state.stack), text_buffer: ""}}
  end

  defp handle_end("defaultOutputEntry", state) do
    text = String.trim(state.text_buffer)
    %Output{} = current_output = state.current_output
    output = %{current_output | default_output_value: if(text == "", do: nil, else: text)}
    {:ok, %{state | current_output: output, stack: tl(state.stack), text_buffer: ""}}
  end

  defp handle_end("rule", state) do
    rule = finalize_rule(state.current_rule)
    %DecisionTable{} = current_table = state.current_decision_table
    table = %{current_table | rules: [rule | current_table.rules]}
    {:ok, %{state | current_decision_table: table, current_rule: nil, stack: tl(state.stack)}}
  end

  defp handle_end("inputEntry", state) do
    [{:input_entry, entry_id} | rest_stack] = state.stack
    text = String.trim(state.text_buffer)
    entry = %InputEntry{id: entry_id, text: if(text == "", do: "-", else: text)}
    %Rule{} = current_rule = state.current_rule
    rule = %{current_rule | input_entries: [entry | current_rule.input_entries]}
    {:ok, %{state | current_rule: rule, stack: rest_stack, text_buffer: ""}}
  end

  defp handle_end("outputEntry", state) do
    [{:output_entry, entry_id} | rest_stack] = state.stack
    text = String.trim(state.text_buffer)
    entry = %OutputEntry{id: entry_id, text: text}
    %Rule{} = current_rule = state.current_rule
    rule = %{current_rule | output_entries: [entry | current_rule.output_entries]}
    {:ok, %{state | current_rule: rule, stack: rest_stack, text_buffer: ""}}
  end

  defp handle_end("description", state) when hd(state.stack) == :rule_description do
    text = String.trim(state.text_buffer)
    %Rule{} = current_rule = state.current_rule
    rule = %{current_rule | description: if(text == "", do: nil, else: text)}
    {:ok, %{state | current_rule: rule, stack: tl(state.stack), text_buffer: ""}}
  end

  defp handle_end("annotationEntry", state) when hd(state.stack) == :annotation_entry do
    text = String.trim(state.text_buffer)
    %Rule{} = current_rule = state.current_rule
    rule = %{current_rule | annotation_entries: [text | current_rule.annotation_entries]}
    {:ok, %{state | current_rule: rule, stack: tl(state.stack), text_buffer: ""}}
  end

  defp handle_end("literalExpression", state) do
    literal = state.current_literal_expression
    state = attach_completed_expression(%{state | current_literal_expression: nil}, literal)
    {:ok, %{state | stack: tl(state.stack)}}
  end

  defp handle_end("text", state) do
    text = state.text_buffer

    state =
      cond do
        state.current_literal_expression != nil ->
          %LiteralExpression{} = current_literal = state.current_literal_expression
          literal = %{current_literal | text: text}
          %{state | current_literal_expression: literal}

        match?([{:input_entry, _} | _], state.stack) ->
          state

        true ->
          state
      end

    {:ok, %{state | stack: tl(state.stack)}}
  end

  defp handle_end("inputData", state) when hd(state.stack) == :service_input_data do
    {:ok, %{state | stack: tl(state.stack)}}
  end

  defp handle_end("inputData", state) do
    {:ok, %{state | stack: tl(state.stack)}}
  end

  defp handle_end("informationRequirement", state) do
    requirement = state.current_information_requirement
    %Decision{} = current_decision = state.current_decision

    decision = %{
      current_decision
      | information_requirements: [requirement | current_decision.information_requirements]
    }

    {:ok,
     %{
       state
       | current_decision: decision,
         current_information_requirement: nil,
         stack: tl(state.stack)
     }}
  end

  # --- End: businessKnowledgeModel (2A) --------------------------------------

  defp handle_end("encapsulatedLogic", state) do
    %FunctionDefinition{} = function_definition = state.current_function_definition

    function_definition = %{
      function_definition
      | formal_parameters: Enum.reverse(function_definition.formal_parameters)
    }

    %BusinessKnowledgeModel{} = current_business_knowledge_model = state.current_business_knowledge_model
    updated_business_knowledge_model = %{current_business_knowledge_model | encapsulated_logic: function_definition}

    {:ok,
     %{
       state
       | current_business_knowledge_model: updated_business_knowledge_model,
         current_function_definition: nil,
         stack: tl(state.stack)
     }}
  end

  defp handle_end("functionDefinition", state) when hd(state.stack) == :function_definition do
    %FunctionDefinition{} = function_definition = state.current_function_definition

    function_definition = %{
      function_definition
      | formal_parameters: Enum.reverse(function_definition.formal_parameters)
    }

    state =
      state
      |> Map.put(:current_function_definition, nil)
      |> Map.update!(:stack, &tl/1)

    state = attach_completed_expression(state, function_definition)
    {:ok, state}
  end

  defp handle_end("businessKnowledgeModel", state) do
    business_knowledge_model = state.current_business_knowledge_model

    {:ok,
     %{
       state
       | business_knowledge_models: [business_knowledge_model | state.business_knowledge_models],
         current_business_knowledge_model: nil,
         stack: tl(state.stack)
     }}
  end

  # --- End: CL3 Boxed expressions (delegated to BoxedExpressions) -----------

  defp handle_end("contextEntry", state), do: BoxedExpressions.end_context_entry(state)
  defp handle_end("context", state) when hd(state.stack) == :context, do: BoxedExpressions.end_context(state)
  defp handle_end("binding", state), do: BoxedExpressions.end_binding(state)
  defp handle_end("invocation", state) when hd(state.stack) == :invocation, do: BoxedExpressions.end_invocation(state)
  defp handle_end("list", state) when hd(state.stack) == :list, do: BoxedExpressions.end_list(state)
  defp handle_end("row", state) when hd(state.stack) == :relation_row, do: BoxedExpressions.end_row(state)
  defp handle_end("relation", state) when hd(state.stack) == :relation, do: BoxedExpressions.end_relation(state)

  defp handle_end("if", state) when hd(state.stack) == :conditional_if,
    do: BoxedExpressions.end_conditional_branch(state)

  defp handle_end("then", state) when hd(state.stack) == :conditional_then,
    do: BoxedExpressions.end_conditional_branch(state)

  defp handle_end("else", state) when hd(state.stack) == :conditional_else,
    do: BoxedExpressions.end_conditional_branch(state)

  defp handle_end("conditional", state) when hd(state.stack) == :conditional,
    do: BoxedExpressions.end_conditional(state)

  defp handle_end("in", state) when hd(state.stack) == :filter_in, do: BoxedExpressions.end_filter_child(state)
  defp handle_end("match", state) when hd(state.stack) == :filter_match, do: BoxedExpressions.end_filter_child(state)
  defp handle_end("filter", state) when hd(state.stack) == :filter, do: BoxedExpressions.end_filter(state)
  defp handle_end("in", state) when hd(state.stack) == :for_in, do: BoxedExpressions.end_for_child(state)
  defp handle_end("return", state) when hd(state.stack) == :for_return, do: BoxedExpressions.end_for_child(state)
  defp handle_end("for", state) when hd(state.stack) == :for, do: BoxedExpressions.end_for(state)
  defp handle_end("in", state) when hd(state.stack) == :every_in, do: BoxedExpressions.end_every_child(state)

  defp handle_end("satisfies", state) when hd(state.stack) == :every_satisfies,
    do: BoxedExpressions.end_every_child(state)

  defp handle_end("every", state) when hd(state.stack) == :every, do: BoxedExpressions.end_every(state)
  defp handle_end("in", state) when hd(state.stack) == :some_in, do: BoxedExpressions.end_some_child(state)

  defp handle_end("satisfies", state) when hd(state.stack) == :some_satisfies,
    do: BoxedExpressions.end_some_child(state)

  defp handle_end("some", state) when hd(state.stack) == :some, do: BoxedExpressions.end_some(state)

  # --- End: knowledgeRequirement (2B) ----------------------------------------

  defp handle_end("knowledgeRequirement", state) do
    requirement = state.current_knowledge_requirement

    {parent_tag, _rest} = find_parent_context(state.stack)

    state =
      case parent_tag do
        :decision ->
          %Decision{} = current_decision = state.current_decision

          decision = %{
            current_decision
            | knowledge_requirements: [
                requirement | current_decision.knowledge_requirements
              ]
          }

          %{state | current_decision: decision}

        :business_knowledge_model ->
          %BusinessKnowledgeModel{} = current_business_knowledge_model = state.current_business_knowledge_model

          updated_business_knowledge_model = %{
            current_business_knowledge_model
            | knowledge_requirements: [
                requirement | current_business_knowledge_model.knowledge_requirements
              ]
          }

          %{state | current_business_knowledge_model: updated_business_knowledge_model}

        _ ->
          state
      end

    {:ok,
     %{
       state
       | current_knowledge_requirement: nil,
         stack: tl(state.stack)
     }}
  end

  # --- End: knowledgeSource (2C) ---------------------------------------------

  defp handle_end("knowledgeSource", state) do
    knowledge_source = state.current_knowledge_source

    knowledge_source = %{
      knowledge_source
      | authority_requirements: Enum.reverse(knowledge_source.authority_requirements)
    }

    {:ok,
     %{
       state
       | knowledge_sources: [knowledge_source | state.knowledge_sources],
         current_knowledge_source: nil,
         stack: tl(state.stack)
     }}
  end

  # --- End: decisionService ---------------------------------------------------

  defp handle_end("outputDecision", state), do: {:ok, %{state | stack: tl(state.stack)}}
  defp handle_end("encapsulatedDecision", state), do: {:ok, %{state | stack: tl(state.stack)}}
  defp handle_end("inputDecision", state), do: {:ok, %{state | stack: tl(state.stack)}}

  defp handle_end("decisionService", state) do
    service = state.current_decision_service

    service = %{
      service
      | output_decisions: Enum.reverse(service.output_decisions),
        encapsulated_decisions: Enum.reverse(service.encapsulated_decisions),
        input_decisions: Enum.reverse(service.input_decisions),
        input_data: Enum.reverse(service.input_data)
    }

    {:ok,
     %{
       state
       | decision_services: [service | state.decision_services],
         current_decision_service: nil,
         stack: tl(state.stack)
     }}
  end

  # --- End: authorityRequirement (2D) ----------------------------------------

  defp handle_end("authorityRequirement", state) do
    requirement = state.current_authority_requirement

    {parent_tag, _rest} = find_parent_context(state.stack)

    state =
      case parent_tag do
        :decision ->
          %Decision{} = current_decision = state.current_decision

          decision = %{
            current_decision
            | authority_requirements: [
                requirement | current_decision.authority_requirements
              ]
          }

          %{state | current_decision: decision}

        :business_knowledge_model ->
          %BusinessKnowledgeModel{} = current_business_knowledge_model = state.current_business_knowledge_model

          updated_business_knowledge_model = %{
            current_business_knowledge_model
            | authority_requirements: [
                requirement | current_business_knowledge_model.authority_requirements
              ]
          }

          %{state | current_business_knowledge_model: updated_business_knowledge_model}

        :knowledge_source ->
          %KnowledgeSource{} = current_knowledge_source = state.current_knowledge_source

          updated_knowledge_source = %{
            current_knowledge_source
            | authority_requirements: [
                requirement | current_knowledge_source.authority_requirements
              ]
          }

          %{state | current_knowledge_source: updated_knowledge_source}

        _ ->
          state
      end

    {:ok,
     %{
       state
       | current_authority_requirement: nil,
         stack: tl(state.stack)
     }}
  end

  # --- End: itemDefinition (2E) ----------------------------------------------

  defp handle_end("itemComponent", state) do
    completed_component = state.current_item_definition

    [parent | rest_stack] = state.item_definition_stack

    parent = %{
      parent
      | item_components: [completed_component | parent.item_components]
    }

    {:ok,
     %{
       state
       | current_item_definition: parent,
         item_definition_stack: rest_stack,
         stack: tl(state.stack)
     }}
  end

  defp handle_end("itemDefinition", state) do
    completed = state.current_item_definition

    completed = %{
      completed
      | item_components: Enum.reverse(completed.item_components)
    }

    case state.item_definition_stack do
      [] ->
        {:ok,
         %{
           state
           | item_definitions: [completed | state.item_definitions],
             current_item_definition: nil,
             stack: tl(state.stack)
         }}

      [parent | rest_stack] ->
        parent = %{
          parent
          | item_components: [completed | parent.item_components]
        }

        {:ok,
         %{
           state
           | current_item_definition: parent,
             item_definition_stack: rest_stack,
             stack: tl(state.stack)
         }}
    end
  end

  defp handle_end("typeRef", state) when hd(state.stack) == :type_ref do
    text = String.trim(state.text_buffer)
    %ItemDefinition{} = current_item = state.current_item_definition
    item_def = %{current_item | type_ref: if(text == "", do: nil, else: text)}
    {:ok, %{state | current_item_definition: item_def, stack: tl(state.stack), text_buffer: ""}}
  end

  defp handle_end("allowedValues", state) when hd(state.stack) == :allowed_values do
    text = String.trim(state.text_buffer)
    %ItemDefinition{} = current_item = state.current_item_definition
    item_def = %{current_item | allowed_values: if(text == "", do: nil, else: text)}
    {:ok, %{state | current_item_definition: item_def, stack: tl(state.stack), text_buffer: ""}}
  end

  # --- End: import (2F) ------------------------------------------------------

  defp handle_end("import", state) do
    {:ok, %{state | stack: tl(state.stack)}}
  end

  # --- End: catch-all --------------------------------------------------------

  defp handle_end(_name, state), do: {:ok, state}

  # === Generic expression attachment =========================================
  #
  # When any expression body completes (decision table, literal expression,
  # boxed context, invocation, list, etc.), this function inspects the stack
  # to determine which parent container should receive it.

  defp attach_completed_expression(state, expression) do
    BoxedExpressions.attach_completed_expression(state, expression)
  end

  # === Helpers ===============================================================

  defp local_name(name) do
    case String.split(name, ":", parts: 2) do
      [_prefix, local] -> local
      [local] -> local
    end
  end

  defp attribute_map(attributes) do
    Map.new(attributes, fn {key, value} -> {local_name(key), value} end)
  end

  defp extract_href(nil), do: nil
  defp extract_href("#" <> id), do: id
  defp extract_href(href), do: href

  defp find_parent_context(stack) do
    stack
    |> tl()
    |> Enum.reduce_while({nil, []}, fn tag, {_found, skipped} ->
      if tag in [:decision, :business_knowledge_model, :knowledge_source] do
        {:halt, {tag, skipped}}
      else
        {:cont, {nil, [tag | skipped]}}
      end
    end)
  end

  defp finalize_decision(%Decision{} = decision) do
    %{
      decision
      | information_requirements: Enum.reverse(decision.information_requirements),
        knowledge_requirements: Enum.reverse(decision.knowledge_requirements),
        authority_requirements: Enum.reverse(decision.authority_requirements)
    }
  end

  defp finalize_bkm(%BusinessKnowledgeModel{} = bkm) do
    %{
      bkm
      | knowledge_requirements: Enum.reverse(bkm.knowledge_requirements),
        authority_requirements: Enum.reverse(bkm.authority_requirements)
    }
  end

  defp finalize_decision_table(%DecisionTable{} = table) do
    %{
      table
      | inputs: Enum.reverse(table.inputs),
        outputs: Enum.reverse(table.outputs),
        rules: Enum.reverse(table.rules)
    }
  end

  defp finalize_rule(%Rule{} = rule) do
    %{
      rule
      | input_entries: Enum.reverse(rule.input_entries),
        output_entries: Enum.reverse(rule.output_entries),
        annotation_entries: Enum.reverse(rule.annotation_entries)
    }
  end

  defp begin_function_definition(state, attrs, stack_tag) do
    kind_raw = attrs["kind"] || "FEEL"

    function_type =
      case String.downcase(kind_raw) do
        "feel" -> :feel
        "java" -> :java
        "pmml" -> :pmml
        _ -> :unsupported
      end

    function_definition = %FunctionDefinition{
      id: attrs["id"],
      type: function_type
    }

    %{
      state
      | current_function_definition: function_definition,
        stack: [stack_tag | state.stack]
    }
  end
end
