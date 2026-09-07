defmodule EvilEngineWeb.Graphql.ModelTypes do
  @moduledoc """
  Absinthe type definitions for the BPMN Model graph (Phase 6.1, WP-2).

  Projects `EvilEngine.BPMN.Model.*` as a first-class, read-only GraphQL
  graph resolved from `EvilEngine.BPMN.ModelCache`. Types here are
  `import_types`-ed into `EvilEngineWeb.Graphql.Schema`, alongside the
  AshGraphql-generated persistence types.

  ## Design (see the plan for full rationale)

  - **D-1 = A**: `:flow_node_type` is struct-aligned (one value per
    `FlowNodeData.*` module); event *kind* is exposed separately via the
    `:event_definition` union on the node, not folded into the enum.
  - **D-2 = C**: `ProcessModel.flowNodes` is the nested tree (recursing via
    `SubProcessNode.flowNodes`); `ProcessModel.allFlowNodes` is the flat,
    every-scope index, each entry carrying `parentSubProcessId`.
  - **D-3 = B**: `ModelSchema.FieldTable.verify!/0` runs at compile time
    (below) and fails the build if any struct field is neither mapped to a
    GraphQL field here nor explicitly excluded there.

  Resolution values are pre-flattened maps built by
  `EvilEngineWeb.Graphql.ModelResolvers.to_graphql_flow_node/2` — the
  polymorphic `type_data` struct is merged onto the wrapper's fields before
  Absinthe's default `Map.get/2` resolution runs, so every field below
  resolves without a per-field `resolve` function. Leaf structs
  (`Mapping`, `DataAssociation`, `DataContract`, `MultiInstance`,
  `StandardLoop`, `EventDefinition.*`) are passed through as-is — their
  field names already match 1:1.
  """

  use Absinthe.Schema.Notation

  import EvilEngineWeb.Graphql.ModelSchema.CommonFields

  alias EvilEngine.BPMN.Model
  alias EvilEngineWeb.Graphql.ModelSchema.FieldTable

  # Compile-time completeness check (D-3). Fails `mix compile` if any
  # `Model.*` struct field is unaccounted for in the field table.
  FieldTable.verify!()

  # ---------------------------------------------------------------------
  # Scalars
  #
  # `:json` is not defined here — AshGraphql already registers a `:json`
  # scalar (`deps/ash_graphql/lib/types/json.ex`) on the same schema, and
  # Absinthe requires globally unique type identifiers. Form schemas, JSON
  # Schema contracts, and extension attribute maps below reuse that scalar.
  # ---------------------------------------------------------------------
  # FlowNodeType enum (D-1 = A — struct-aligned, 21 values)
  # ---------------------------------------------------------------------

  @desc "The kind of a BPMN flow node, aligned 1:1 with `EvilEngine.BPMN.Model.FlowNodeData.*`. Event kind (message/timer/error/...) is not folded in here — see the `EventDefinition` union on event-position nodes."
  enum :flow_node_type do
    value(:task)
    value(:user_task)
    value(:service_task)
    value(:manual_task)
    value(:script_task)
    value(:business_rule_task)
    value(:send_task)
    value(:receive_task)
    value(:call_activity)
    value(:sub_process)
    value(:exclusive_gateway)
    value(:parallel_gateway)
    value(:inclusive_gateway)
    value(:event_based_gateway)
    value(:complex_gateway)
    value(:start_event)
    value(:end_event)
    value(:intermediate_catch_event)
    value(:intermediate_throw_event)
    value(:boundary_event)
    value(:unknown)
  end

  @desc "Standard BPMN loop ordering for a multi-instance activity."
  enum :multi_instance_ordering do
    value(:sequential)
    value(:parallel)
  end

  @desc "Direction of a data contract relative to the owning flow node."
  enum :data_contract_direction do
    value(:input)
    value(:output)
  end

  # ---------------------------------------------------------------------
  # EventDefinition union (11 members)
  # ---------------------------------------------------------------------

  object :none_event_definition do
    @desc "Marker field — a `None` event definition carries no data."
    field :is_none, non_null(:boolean) do
      resolve(fn _, _, _ -> {:ok, true} end)
    end
  end

  object :message_event_definition do
    field(:message_ref, :string)
    field(:correlation_retrieval_expression, :string)
  end

  object :signal_event_definition do
    field(:signal_ref, :string)
  end

  object :timer_event_definition do
    field(:time_date, :string)
    field(:time_duration, :string)
    field(:time_cycle, :string)
  end

  object :error_event_definition do
    field(:error_ref, :string)
    field(:error_code, :string)
    field(:error_message, :string)
  end

  object :escalation_event_definition do
    field(:escalation_ref, :string)
    field(:escalation_code, :string)
  end

  object :conditional_event_definition do
    field(:condition_expression, :string)
  end

  object :compensation_event_definition do
    field(:activity_ref, :string)
    field(:wait_for_completion, non_null(:boolean))
  end

  object :terminate_event_definition do
    field :is_terminate, non_null(:boolean) do
      resolve(fn _, _, _ -> {:ok, true} end)
    end
  end

  object :cancel_event_definition do
    field :is_cancel, non_null(:boolean) do
      resolve(fn _, _, _ -> {:ok, true} end)
    end
  end

  object :link_event_definition do
    field(:link_name, :string)
  end

  @desc "The trigger-specific payload of an event-position flow node (Start/End/IntermediateCatch/IntermediateThrow/Boundary). Exactly one concrete type per `EvilEngine.BPMN.Model.EventDefinition.*` struct."
  union :event_definition do
    types([
      :none_event_definition,
      :message_event_definition,
      :signal_event_definition,
      :timer_event_definition,
      :error_event_definition,
      :escalation_event_definition,
      :conditional_event_definition,
      :compensation_event_definition,
      :terminate_event_definition,
      :cancel_event_definition,
      :link_event_definition
    ])

    resolve_type(fn
      %Model.EventDefinition.None{}, _ -> :none_event_definition
      %Model.EventDefinition.Message{}, _ -> :message_event_definition
      %Model.EventDefinition.Signal{}, _ -> :signal_event_definition
      %Model.EventDefinition.Timer{}, _ -> :timer_event_definition
      %Model.EventDefinition.Error{}, _ -> :error_event_definition
      %Model.EventDefinition.Escalation{}, _ -> :escalation_event_definition
      %Model.EventDefinition.Conditional{}, _ -> :conditional_event_definition
      %Model.EventDefinition.Compensation{}, _ -> :compensation_event_definition
      %Model.EventDefinition.Terminate{}, _ -> :terminate_event_definition
      %Model.EventDefinition.Cancel{}, _ -> :cancel_event_definition
      %Model.EventDefinition.Link{}, _ -> :link_event_definition
      _other, _ -> nil
    end)
  end

  # ---------------------------------------------------------------------
  # Leaf / supporting object types
  # ---------------------------------------------------------------------

  object :mapping do
    field(:source, non_null(:string))
    field(:target, non_null(:string))
  end

  object :data_association do
    field(:id, non_null(:id))
    field(:source_ref, :string)
    field(:target_ref, :string)
    field(:value_expression, :string)
  end

  object :data_contract do
    field(:direction, non_null(:data_contract_direction))
    field(:json_schema, non_null(:json))
  end

  object :multi_instance do
    field(:is_sequential, non_null(:boolean))
    field(:collection_expression, :string)
    field(:element_variable, :string)
    field(:completion_condition, :string)
    field(:output_collection, :string)
    field(:output_element_variable, :string)
    field(:loop_break_condition, :string)
    field(:loop_interval, :string)
    field(:max_iterations, :integer)
  end

  object :standard_loop do
    field(:test_before, non_null(:boolean))
    field(:loop_condition, :string)
    field(:loop_maximum, :integer)
    field(:loop_interval, :string)
  end

  object :sequence_flow do
    field(:id, non_null(:id))
    field(:name, :string)
    field(:source_ref, non_null(:string))
    field(:target_ref, non_null(:string))
    field(:condition_expression, :string)
    field(:is_default, non_null(:boolean))
  end

  object :lane do
    field(:id, non_null(:id))
    field(:name, :string)
    field(:flow_node_refs, non_null(list_of(non_null(:string))))
  end

  object :data_object_model do
    field(:id, non_null(:id))
    field(:name, :string)
    field(:item_subject_ref, :string)
    field(:value_contract, :json)
  end

  object :data_object_reference_model do
    field(:id, non_null(:id))
    field(:name, :string)
    field(:data_object_ref, :string)
    field(:data_state, :string)
  end

  object :association do
    field(:id, non_null(:id))
    field(:source_ref, :string)
    field(:target_ref, :string)
    field(:association_direction, :string)
  end

  object :bpmn_extension do
    field(:key, non_null(:string))
    field(:value, :string)
    field(:attributes, non_null(:json))
    field(:children, non_null(list_of(non_null(:bpmn_extension))))
  end

  object :linter_ruleset_score do
    field(:ruleset_id, non_null(:string))
    field(:score_percent, :float)
    field(:compliance_status, :string)
    field(:computed_at_iso, :string)
    field(:schema_version, :string)
    field(:max_points, :float)
    field(:penalty_points, :float)
    field(:raw_error_findings, :integer)
    field(:raw_warning_findings, :integer)
  end

  object :message_definition do
    field(:id, non_null(:id))
    field(:name, :string)
  end

  object :signal_definition do
    field(:id, non_null(:id))
    field(:name, :string)
  end

  object :error_definition do
    field(:id, non_null(:id))
    field(:name, :string)
    field(:error_code, :string)
  end

  object :escalation_definition do
    field(:id, non_null(:id))
    field(:name, :string)
    field(:escalation_code, :string)
  end

  # ---------------------------------------------------------------------
  # FlowNode interface — common fields shared by every concrete node type
  # ---------------------------------------------------------------------

  @desc "A polymorphic BPMN flow node. Concrete type is one of the 21 `*Node` types below, aligned 1:1 with `EvilEngine.BPMN.Model.FlowNodeData.*`."
  interface :flow_node do
    common_flow_node_fields()

    resolve_type(fn %{type: type}, _ ->
      case type do
        :task -> :task_node
        :user_task -> :user_task_node
        :service_task -> :service_task_node
        :manual_task -> :manual_task_node
        :script_task -> :script_task_node
        :business_rule_task -> :business_rule_task_node
        :send_task -> :send_task_node
        :receive_task -> :receive_task_node
        :call_activity -> :call_activity_node
        :sub_process -> :sub_process_node
        :exclusive_gateway -> :exclusive_gateway_node
        :parallel_gateway -> :parallel_gateway_node
        :inclusive_gateway -> :inclusive_gateway_node
        :event_based_gateway -> :event_based_gateway_node
        :complex_gateway -> :complex_gateway_node
        :start_event -> :start_event_node
        :end_event -> :end_event_node
        :intermediate_catch_event -> :intermediate_catch_event_node
        :intermediate_throw_event -> :intermediate_throw_event_node
        :boundary_event -> :boundary_event_node
        :unknown -> :unknown_node
        _other -> nil
      end
    end)
  end

  # ---------------------------------------------------------------------
  # Concrete FlowNode*Node object types (21, one per FlowNodeData struct)
  # ---------------------------------------------------------------------

  # Task / Parallel Gateway / Event-Based Gateway have no type-specific
  # fields beyond the FlowNode interface. GraphQL clients must not emit
  # empty inline fragments (`... on TaskNode { }`) for these types —
  # Absinthe rejects empty selection sets as `syntax error before: '}'`.
  object :task_node do
    interface(:flow_node)
    common_flow_node_fields()
  end

  object :user_task_node do
    interface(:flow_node)
    common_flow_node_fields()
    mapping_fields()
    field(:form_schema, :json)
    field(:form_actions, :json)
    field(:assignees_expression, :string)
    field(:payload_contract, :json)
    field(:result_contract, :json)
    field(:due_date, :string)
    field(:priority, :integer)
  end

  object :service_task_node do
    interface(:flow_node)
    common_flow_node_fields()
    mapping_fields()
    field(:implementation, :string)
    field(:payload_contract, :json)
    field(:result_contract, :json)
    field(:http_url, :string)
    field(:http_method, :string)
    field(:http_body, :string)
    field(:http_auth_header, :string)
    field(:http_response_headers, :string)
  end

  object :manual_task_node do
    interface(:flow_node)
    common_flow_node_fields()
    field(:require_confirmation, non_null(:boolean))
  end

  object :script_task_node do
    interface(:flow_node)
    common_flow_node_fields()
    mapping_fields()
    field(:script_format, :string)
    field(:script, :string)
    field(:script_ref, :string)
    field(:payload_contract, :json)
    field(:result_contract, :json)
  end

  object :business_rule_task_node do
    interface(:flow_node)
    common_flow_node_fields()
    mapping_fields()
    field(:implementation, :string)
    field(:script, :string)

    @desc "Legacy field, parsed for XML fidelity only. The validator rejects `implementation=\"plugin\"`, so this is never the decision actually invoked — use `decisionRef`."
    field(:rule_ref, :string)
    field(:decision_ref, :string)
    field(:decision_element_id, :string)
    field(:result_variable, :string)
    field(:trace_unmatched_rules, non_null(:boolean))
    field(:payload_contract, :json)
    field(:result_contract, :json)
  end

  object :send_task_node do
    interface(:flow_node)
    common_flow_node_fields()
    mapping_fields()
    field(:message_ref, :string)
    field(:payload_contract, :json)
  end

  object :receive_task_node do
    interface(:flow_node)
    common_flow_node_fields()
    field(:in_mappings, non_null(list_of(non_null(:mapping))))
    field(:out_mappings, non_null(list_of(non_null(:mapping))))
    field(:message_ref, :string)
    field(:result_contract, :json)
  end

  object :call_activity_node do
    interface(:flow_node)
    common_flow_node_fields()
    mapping_fields()
    field(:called_element, :string)
    field(:start_event_id, :string)
  end

  object :sub_process_node do
    interface(:flow_node)
    common_flow_node_fields()
    mapping_fields()
    field(:triggered_by_event, non_null(:boolean))
    field(:is_transaction, non_null(:boolean))
    field(:transaction_method, :string)
    field(:is_ad_hoc, non_null(:boolean))
    field(:adhoc_ordering, :multi_instance_ordering)
    field(:cancel_remaining_instances, non_null(:boolean))
    field(:adhoc_completion_condition, :string)
    field(:implementation, :string)
    field(:active_elements_expression, :string)
    field(:payload_contract, :json)
    field(:result_contract, :json)
    field(:data_objects, non_null(list_of(non_null(:data_object_model))))
    field(:data_object_references, non_null(list_of(non_null(:data_object_reference_model))))
    field(:flow_nodes, non_null(list_of(non_null(:flow_node))))
    field(:sequence_flows, non_null(list_of(non_null(:sequence_flow))))
  end

  object :exclusive_gateway_node do
    interface(:flow_node)
    common_flow_node_fields()
    field(:default_flow_ref, :string)
  end

  object :parallel_gateway_node do
    interface(:flow_node)
    common_flow_node_fields()
  end

  object :inclusive_gateway_node do
    interface(:flow_node)
    common_flow_node_fields()
    field(:default_flow_ref, :string)
  end

  object :event_based_gateway_node do
    interface(:flow_node)
    common_flow_node_fields()
  end

  object :complex_gateway_node do
    interface(:flow_node)
    common_flow_node_fields()
    field(:activation_condition, :string)
  end

  object :unknown_node do
    interface(:flow_node)
    common_flow_node_fields()
    field(:element_name, :string)
    field(:attributes, :json)
  end

  object :start_event_node do
    interface(:flow_node)
    common_flow_node_fields()
    field(:event_definition, non_null(:event_definition))
    field(:result_contract, :json)
    field(:is_interrupting, non_null(:boolean))
  end

  object :end_event_node do
    interface(:flow_node)
    common_flow_node_fields()
    field(:event_definition, non_null(:event_definition))
    field(:in_mappings, non_null(list_of(non_null(:mapping))))
    field(:payload_contract, :json)
  end

  object :intermediate_catch_event_node do
    interface(:flow_node)
    common_flow_node_fields()
    field(:event_definition, non_null(:event_definition))
    field(:out_mappings, non_null(list_of(non_null(:mapping))))
    field(:result_contract, :json)
  end

  object :intermediate_throw_event_node do
    interface(:flow_node)
    common_flow_node_fields()
    field(:event_definition, non_null(:event_definition))
    field(:in_mappings, non_null(list_of(non_null(:mapping))))
    field(:payload_contract, :json)
  end

  object :boundary_event_node do
    interface(:flow_node)
    common_flow_node_fields()
    field(:event_definition, non_null(:event_definition))
    field(:attached_to_ref, :string)
    field(:cancel_activity, non_null(:boolean))
    field(:compensation_handler_id, :string)
    field(:out_mappings, non_null(list_of(non_null(:mapping))))
    field(:result_contract, :json)
  end

  # ---------------------------------------------------------------------
  # ProcessModel (D-2 = C — nested tree + flat index)
  # ---------------------------------------------------------------------

  @desc "The parsed BPMN process, projected from `EvilEngine.BPMN.Model.Process` via `ModelCache`. Named `ProcessModel` (not `Process`) to avoid colliding with the persistence-layer `Process` GraphQL type."
  object :process_model do
    field(:id, non_null(:id))
    field(:name, :string)
    field(:version, :string)
    field(:is_executable, non_null(:boolean))
    field(:is_transaction_scope, non_null(:boolean))
    field(:is_ad_hoc_scope, non_null(:boolean))
    field(:correlation_key, :string)

    @desc "Top-level flow nodes only. Nested subprocess scopes recurse via SubProcessNode.flowNodes. Use `allFlowNodes` for a flat, every-scope lookup."
    field(:flow_nodes, non_null(list_of(non_null(:flow_node))))

    @desc "Every flow node across every scope (top-level and nested subprocesses alike), flattened. Each entry carries `parentSubProcessId`. This is what `FlowNodeInstance.flowNode` resolves against."
    field(:all_flow_nodes, non_null(list_of(non_null(:flow_node))))

    field(:sequence_flows, non_null(list_of(non_null(:sequence_flow))))
    field(:lanes, non_null(list_of(non_null(:lane))))
    field(:data_objects, non_null(list_of(non_null(:data_object_model))))
    field(:data_object_references, non_null(list_of(non_null(:data_object_reference_model))))
    field(:associations, non_null(list_of(non_null(:association))))
    field(:extensions, non_null(list_of(non_null(:bpmn_extension))))

    @desc "BPMN `<definitions>` id of the source document this process was parsed from."
    field(:definitions_id, :id)

    field(:messages, non_null(list_of(non_null(:message_definition))))
    field(:signals, non_null(list_of(non_null(:signal_definition))))
    field(:errors, non_null(list_of(non_null(:error_definition))))
    field(:escalations, non_null(list_of(non_null(:escalation_definition))))
    field(:linter_scores, non_null(list_of(non_null(:linter_ruleset_score))))
  end
end
