defmodule EvilEngineWeb.Graphql.ModelSchema.FieldTable do
  @moduledoc """
  Declarative per-struct field table for the GraphQL Model graph (D-3 = B).

  Every `EvilEngine.BPMN.Model.*` / `FlowNodeData.*` / `EventDefinition.*`
  struct that the Model graph projects is registered here with two disjoint
  lists:

  - `exposed` — struct keys that appear as a GraphQL field, either directly
    (same name) or flattened onto the concrete `*Node` object type.
  - `excluded` — struct keys deliberately **not** exposed, each with a
    one-line reason (compiled artifacts, deploy-time analysis caches, or
    fields superseded by a persistence-layer field).

  `verify!/0` is called from `EvilEngineWeb.Graphql.ModelTypes` at compile
  time (a module's body executes during compilation). For every registered
  struct it fetches the actual struct keys via `Map.from_struct/1` — legal
  because `core_bpmn` is a fully-compiled umbrella dependency by the time
  `api_web` compiles — and asserts they exactly match `exposed ++ excluded`.

  **A struct field that is neither mapped nor excluded fails the build.**
  This is the guarantee D-3 asks for: not automatic generation, but a
  guard that makes silent drift impossible. Adding a field to any of these
  structs without touching this table breaks `mix compile`.
  """

  alias EvilEngine.BPMN.Model

  @type entry :: {module(), exposed: [atom()], excluded: [{atom(), String.t()}]}

  @registry [
    # --- Root / container -----------------------------------------------
    {Model.Definitions,
     exposed: [:definitions_id, :messages, :signals, :errors, :escalations, :linter_scores],
     excluded: [
       {:raw_xml, "already exposed as ProcessVersion.bpmnXml on the persistence type"},
       {:processes,
        "selected into ProcessModel via select_process/1 — the graph exposes one executable process, not the collaboration's process list"}
     ]},
    {Model.Process,
     exposed: [
       :id,
       :name,
       :version,
       :is_executable,
       :is_transaction_scope,
       :is_ad_hoc_scope,
       :flow_nodes,
       :sequence_flows,
       :lanes,
       :data_objects,
       :data_object_references,
       :associations,
       :extensions,
       :correlation_key
     ],
     excluded: [
       {:inclusive_join_analyses, "deploy-time graph analysis cache, engine-internal"},
       {:complex_region_analyses, "deploy-time graph analysis cache, engine-internal"}
     ]},
    {Model.MessageDefinition, exposed: [:id, :name], excluded: []},
    {Model.SignalDefinition, exposed: [:id, :name], excluded: []},
    {Model.ErrorDefinition, exposed: [:id, :name, :error_code], excluded: []},
    {Model.EscalationDefinition, exposed: [:id, :name, :escalation_code], excluded: []},

    # --- FlowNode wrapper --------------------------------------------------
    {Model.FlowNode,
     exposed: [
       :id,
       :name,
       :type,
       :incoming,
       :outgoing,
       :boundary_event_refs,
       :data_contracts,
       :data_input_associations,
       :data_output_associations,
       :multi_instance,
       :standard_loop,
       :is_for_compensation,
       :documentation
     ],
     excluded: [
       {:type_data, "polymorphic payload — flattened onto the concrete FlowNode*Node object type"}
     ]},

    # --- FlowNodeData: activities ------------------------------------------
    {Model.FlowNodeData.Task, exposed: [], excluded: []},
    {Model.FlowNodeData.UserTask,
     exposed: [
       :form_schema,
       :form_actions,
       :assignees_expression,
       :payload_contract,
       :result_contract,
       :in_mappings,
       :out_mappings,
       :due_date,
       :priority
     ],
     excluded: []},
    {Model.FlowNodeData.ServiceTask,
     exposed: [
       :implementation,
       :payload_contract,
       :result_contract,
       :in_mappings,
       :out_mappings,
       :http_url,
       :http_method,
       :http_body,
       :http_auth_header,
       :http_response_headers
     ],
     excluded: []},
    {Model.FlowNodeData.ManualTask, exposed: [:require_confirmation], excluded: []},
    {Model.FlowNodeData.ScriptTask,
     exposed: [
       :script_format,
       :script,
       :script_ref,
       :payload_contract,
       :result_contract,
       :in_mappings,
       :out_mappings
     ],
     excluded: []},
    {Model.FlowNodeData.BusinessRuleTask,
     exposed: [
       :implementation,
       :script,
       :rule_ref,
       :decision_ref,
       :decision_element_id,
       :result_variable,
       :trace_unmatched_rules,
       :payload_contract,
       :result_contract,
       :in_mappings,
       :out_mappings
     ],
     excluded: []},
    {Model.FlowNodeData.SendTask,
     exposed: [:message_ref, :payload_contract, :in_mappings, :out_mappings], excluded: []},
    {Model.FlowNodeData.ReceiveTask,
     exposed: [:message_ref, :result_contract, :in_mappings, :out_mappings], excluded: []},
    {Model.FlowNodeData.CallActivity,
     exposed: [:called_element, :start_event_id, :in_mappings, :out_mappings], excluded: []},
    {Model.FlowNodeData.SubProcess,
     exposed: [
       :triggered_by_event,
       :is_transaction,
       :transaction_method,
       :is_ad_hoc,
       :adhoc_ordering,
       :cancel_remaining_instances,
       :adhoc_completion_condition,
       :implementation,
       :active_elements_expression,
       :flow_nodes,
       :sequence_flows,
       :in_mappings,
       :out_mappings,
       :payload_contract,
       :result_contract,
       :data_objects,
       :data_object_references
     ],
     excluded: [
       {:adhoc_completion_condition_compiled,
        "precompiled FEEL reference, opaque and engine-internal"},
       {:active_elements_compiled, "precompiled FEEL reference, opaque and engine-internal"}
     ]},

    # --- FlowNodeData: gateways ---------------------------------------------
    {Model.FlowNodeData.ExclusiveGateway, exposed: [:default_flow_ref], excluded: []},
    {Model.FlowNodeData.ParallelGateway, exposed: [], excluded: []},
    {Model.FlowNodeData.InclusiveGateway, exposed: [:default_flow_ref], excluded: []},
    {Model.FlowNodeData.EventBasedGateway, exposed: [], excluded: []},
    {Model.FlowNodeData.ComplexGateway, exposed: [:activation_condition], excluded: []},

    # --- FlowNodeData: catch-all ---------------------------------------------
    {Model.FlowNodeData.Unknown, exposed: [:element_name, :attributes], excluded: []},

    # --- FlowNodeData: event positions --------------------------------------
    {Model.FlowNodeData.StartEvent,
     exposed: [:event_definition, :result_contract, :is_interrupting], excluded: []},
    {Model.FlowNodeData.EndEvent,
     exposed: [:event_definition, :in_mappings, :payload_contract], excluded: []},
    {Model.FlowNodeData.IntermediateCatchEvent,
     exposed: [:event_definition, :out_mappings, :result_contract], excluded: []},
    {Model.FlowNodeData.IntermediateThrowEvent,
     exposed: [:event_definition, :in_mappings, :payload_contract], excluded: []},
    {Model.FlowNodeData.BoundaryEvent,
     exposed: [
       :event_definition,
       :attached_to_ref,
       :cancel_activity,
       :compensation_handler_id,
       :out_mappings,
       :result_contract
     ],
     excluded: []},

    # --- EventDefinition -----------------------------------------------------
    {Model.EventDefinition.None, exposed: [], excluded: []},
    {Model.EventDefinition.Message,
     exposed: [
       :message_ref,
       :correlation_retrieval_expression
     ],
     excluded: []},
    {Model.EventDefinition.Signal, exposed: [:signal_ref], excluded: []},
    {Model.EventDefinition.Timer,
     exposed: [:time_date, :time_duration, :time_cycle], excluded: []},
    {Model.EventDefinition.Error,
     exposed: [:error_ref, :error_code, :error_message], excluded: []},
    {Model.EventDefinition.Escalation,
     exposed: [:escalation_ref, :escalation_code], excluded: []},
    {Model.EventDefinition.Conditional, exposed: [:condition_expression], excluded: []},
    {Model.EventDefinition.Compensation,
     exposed: [:activity_ref, :wait_for_completion], excluded: []},
    {Model.EventDefinition.Terminate, exposed: [], excluded: []},
    {Model.EventDefinition.Cancel, exposed: [], excluded: []},
    {Model.EventDefinition.Link, exposed: [:link_name], excluded: []},

    # --- Supporting ------------------------------------------------------------
    {Model.SequenceFlow,
     exposed: [:id, :name, :source_ref, :target_ref, :condition_expression, :is_default],
     excluded: []},
    {Model.Lane, exposed: [:id, :name, :flow_node_refs], excluded: []},
    {Model.DataObject, exposed: [:id, :name, :item_subject_ref, :value_contract], excluded: []},
    {Model.DataAssociation,
     exposed: [:id, :source_ref, :target_ref, :value_expression], excluded: []},
    {Model.DataObjectReference,
     exposed: [:id, :name, :data_object_ref, :data_state], excluded: []},
    {Model.Association,
     exposed: [:id, :source_ref, :target_ref, :association_direction], excluded: []},
    {Model.Mapping, exposed: [:source, :target], excluded: []},
    {Model.Extension, exposed: [:key, :value, :attributes, :children], excluded: []},
    {Model.DataContract,
     exposed: [:direction, :json_schema],
     excluded: [
       {:compiled_schema, "precompiled ExJsonSchema reference, opaque and never populated"}
     ]},
    {Model.LinterRulesetScore,
     exposed: [
       :ruleset_id,
       :score_percent,
       :compliance_status,
       :computed_at_iso,
       :schema_version,
       :max_points,
       :penalty_points,
       :raw_error_findings,
       :raw_warning_findings
     ],
     excluded: []},
    {Model.MultiInstance,
     exposed: [
       :is_sequential,
       :collection_expression,
       :element_variable,
       :completion_condition,
       :output_collection,
       :output_element_variable,
       :loop_break_condition,
       :loop_interval,
       :max_iterations
     ],
     excluded: [
       {:loop_cardinality, "rejected at deploy (`loopCardinality` is not supported)"},
       {:compiled_collection,
        "precompiled FEEL reference, opaque and reserved (never populated)"},
       {:compiled_output_collection,
        "precompiled FEEL reference, opaque and reserved (never populated)"},
       {:compiled_completion_condition,
        "precompiled FEEL reference, opaque and reserved (never populated)"},
       {:compiled_loop_break_condition,
        "precompiled FEEL reference, opaque and reserved (never populated)"}
     ]},
    {Model.StandardLoop,
     exposed: [:test_before, :loop_condition, :loop_maximum, :loop_interval],
     excluded: [
       {:compiled_loop_condition,
        "precompiled FEEL reference, opaque and reserved (never populated)"}
     ]}
  ]

  @supporting_graphql_identifiers %{
    Model.MessageDefinition => :message_definition,
    Model.SignalDefinition => :signal_definition,
    Model.ErrorDefinition => :error_definition,
    Model.EscalationDefinition => :escalation_definition,
    Model.SequenceFlow => :sequence_flow,
    Model.Lane => :lane,
    Model.DataObject => :data_object_model,
    Model.DataAssociation => :data_association,
    Model.DataObjectReference => :data_object_reference_model,
    Model.Association => :association,
    Model.Mapping => :mapping,
    Model.Extension => :bpmn_extension,
    Model.DataContract => :data_contract,
    Model.LinterRulesetScore => :linter_ruleset_score,
    Model.MultiInstance => :multi_instance,
    Model.StandardLoop => :standard_loop
  }

  @doc "The full registry, for introspection by tests (e.g. WP-7 test (i))."
  @spec registry() :: [entry()]
  def registry, do: @registry

  @doc """
  Absinthe type identifier that exposes this struct's `exposed` fields.

  Used by the FieldTable → schema field-presence test so a key listed as
  `exposed` that is missing from the corresponding GraphQL type fails the
  suite — `verify!/0` only checks Elixir struct keys against the table.
  """
  @spec graphql_identifier(module()) :: atom()
  def graphql_identifier(Model.Definitions), do: :process_model
  def graphql_identifier(Model.Process), do: :process_model
  def graphql_identifier(Model.FlowNode), do: :flow_node

  def graphql_identifier(module) do
    parts = Module.split(module)

    cond do
      match?(["EvilEngine", "BPMN", "Model", "FlowNodeData", _last], parts) ->
        :"#{Macro.underscore(List.last(parts))}_node"

      match?(["EvilEngine", "BPMN", "Model", "EventDefinition", _last], parts) ->
        :"#{Macro.underscore(List.last(parts))}_event_definition"

      true ->
        Map.fetch!(@supporting_graphql_identifiers, module)
    end
  end

  @doc """
  Verifies that every registered struct's actual field set is covered
  exactly by `exposed ++ excluded`. Raises `ArgumentError` (aborting
  compilation of the calling module) on any mismatch.
  """
  @spec verify!() :: :ok
  def verify! do
    Enum.each(@registry, fn {module, opts} ->
      exposed = Keyword.fetch!(opts, :exposed)
      excluded = Keyword.fetch!(opts, :excluded) |> Enum.map(&elem(&1, 0))
      covered = MapSet.new(exposed ++ excluded)

      actual =
        module
        |> struct()
        |> Map.from_struct()
        |> Map.keys()
        |> MapSet.new()

      unmapped = MapSet.difference(actual, covered)
      stale = MapSet.difference(covered, actual)

      unless MapSet.size(unmapped) == 0 and MapSet.size(stale) == 0 do
        raise ArgumentError, """
        EvilEngineWeb.Graphql.ModelSchema.FieldTable is out of sync with #{inspect(module)}.

        Unmapped fields (present on the struct, missing from `exposed`/`excluded`): #{inspect(MapSet.to_list(unmapped))}
        Stale entries (in the table, no longer on the struct): #{inspect(MapSet.to_list(stale))}

        Every struct field must be either exposed as a GraphQL field or
        excluded with a documented reason. Update field_table.ex.
        """
      end
    end)

    :ok
  end
end
