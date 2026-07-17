defmodule EvilEngine.BPMN.Validator do
  @moduledoc """
  Structural validator for parsed BPMN definitions.

  All violations are collected and returned as a single error with the
  full list, so the user can fix every issue in one pass without
  repeatedly redeploying.

  Checks:
  - Enforced minimum pattern (start/end events)
  - evil:version requirement
  - Essential property completeness (IDs on nodes/flows)
  - Type-specific completeness per FlowNodeData type
  - Event definition completeness per trigger type
  - Boundary event structural integrity
  - Embedded subprocess inner-scope structural integrity (non-event subprocesses only)
  - Cross-boundary sequence flow detection (parent flows must not reference inner nodes)
  - Global flow-node ID uniqueness across a process and every nested subprocess scope
  - Dangling reference detection (sequence flows, data objects, globals)
  - Invalid event-definition/position combos
  - Event-Based Gateway checks (no boundary events on EBG Receive Task targets)
  - Cancel event scope enforcement (Cancel End inside transaction; Cancel Boundary on transaction host)
  - Nested transaction rejection (bpmn:transaction inside bpmn:transaction)
  """

  alias EvilEngine.BPMN.ComplexRegionAnalysis
  alias EvilEngine.BPMN.Model.Definitions
  alias EvilEngine.BPMN.Model.EventDefinition
  alias EvilEngine.BPMN.Model.FlowNode
  alias EvilEngine.BPMN.Model.FlowNodeData
  alias EvilEngine.BPMN.Model.MultiInstance
  alias EvilEngine.BPMN.Model.Process, as: BpmnProcess
  alias EvilEngine.BPMN.Model.SequenceFlow
  alias EvilEngine.BPMN.Model.StandardLoop

  @type violation :: {atom(), String.t()}

  @doc """
  Validate a `%Definitions{}` struct.

  Returns `{:ok, definitions}` when valid, or `{:error, violations}` where
  `violations` is a list of `{code, message}` tuples. All issues are
  collected — the validator never short-circuits on the first problem.
  """
  @spec validate(Definitions.t()) :: {:ok, Definitions.t()} | {:error, [violation()]}
  def validate(%Definitions{} = definitions) do
    violations = Enum.flat_map(definitions.processes, &validate_process(&1, definitions))

    case violations do
      [] -> {:ok, definitions}
      errors -> {:error, errors}
    end
  end

  defp validate_process(%BpmnProcess{is_executable: false}, _definitions), do: []

  defp validate_process(%BpmnProcess{} = process, definitions) do
    List.flatten([
      check_version(process),
      check_start_event(process),
      check_end_event(process),
      check_essential_properties(process),
      check_sequence_flow_refs(process),
      check_event_based_gateways(process),
      check_complex_gateways(process),
      check_orphan_nodes(process),
      check_start_end_flow_direction(process),
      check_data_object_refs(process),
      check_data_association_refs(process),
      check_value_contract_schemas(process),
      check_global_refs(process, definitions),
      check_event_definition_positions(process),
      check_flow_node_completeness(process, definitions),
      check_cross_boundary_flows(process),
      check_event_subprocess_shell_flows(process),
      check_unique_flow_node_ids(process),
      check_cancel_transaction_scope(process),
      check_nested_transactions(process),
      check_loop_characteristics(process)
    ])
  end

  # ---------------------------------------------------------------------------
  # Process-level checks
  # ---------------------------------------------------------------------------

  defp check_version(%BpmnProcess{version: nil, id: id}) do
    [
      {:missing_version,
       "Process '#{id}' is missing required property: version (evil:version)"}
    ]
  end

  defp check_version(%BpmnProcess{version: "", id: id}) do
    [
      {:blank_version,
       "Process '#{id}' has a blank value for required property: version (evil:version)"}
    ]
  end

  defp check_version(_), do: []

  defp check_start_event(%BpmnProcess{id: id} = process) do
    has_start =
      Enum.any?(process.flow_nodes, fn %FlowNode{type: type} -> type == :start_event end)

    if has_start,
      do: [],
      else: [{:missing_start_event, "Process '#{id}' must contain at least one StartEvent"}]
  end

  defp check_end_event(%BpmnProcess{id: id} = process) do
    has_end = Enum.any?(process.flow_nodes, fn %FlowNode{type: type} -> type == :end_event end)

    if has_end,
      do: [],
      else: [{:missing_end_event, "Process '#{id}' must contain at least one EndEvent"}]
  end

  # ---------------------------------------------------------------------------
  # Essential property checks (IDs on nodes and flows)
  # ---------------------------------------------------------------------------

  defp check_essential_properties(%BpmnProcess{} = process) do
    node_errors =
      Enum.flat_map(process.flow_nodes, fn %FlowNode{id: id, type: type} ->
        if blank?(id),
          do: [{:missing_node_id, "#{type_label(type)} is missing required property: id"}],
          else: []
      end)

    flow_errors = Enum.flat_map(process.sequence_flows, &check_sequence_flow_essential_props/1)

    node_errors ++ flow_errors
  end

  defp check_sequence_flow_essential_props(%SequenceFlow{} = sequence_flow) do
    missing = collect_missing_sequence_flow_props(sequence_flow)

    if missing == [] do
      []
    else
      label =
        if blank?(sequence_flow.id),
          do: "SequenceFlow (unknown)",
          else: "SequenceFlow '#{sequence_flow.id}'"

      [
        {:incomplete_sequence_flow,
         "#{label} is missing required properties: #{Enum.join(missing, ", ")}"}
      ]
    end
  end

  defp collect_missing_sequence_flow_props(%SequenceFlow{} = sequence_flow) do
    []
    |> maybe_add(blank?(sequence_flow.id), "id")
    |> maybe_add(blank?(sequence_flow.source_ref), "sourceRef")
    |> maybe_add(blank?(sequence_flow.target_ref), "targetRef")
  end

  # ---------------------------------------------------------------------------
  # Sequence flow reference checks
  # ---------------------------------------------------------------------------

  defp check_sequence_flow_refs(%BpmnProcess{} = process) do
    node_ids = MapSet.new(process.flow_nodes, fn %FlowNode{id: id} -> id end)

    Enum.flat_map(process.sequence_flows, fn %SequenceFlow{} = sequence_flow ->
      check_sequence_flow_source(sequence_flow, node_ids) ++
        check_sequence_flow_target(sequence_flow, node_ids)
    end)
  end

  defp check_sequence_flow_source(%SequenceFlow{id: id, source_ref: ref}, node_ids) do
    if blank?(ref) or MapSet.member?(node_ids, ref),
      do: [],
      else: [
        {:dangling_source_ref, "SequenceFlow '#{id}' references unknown source node '#{ref}'"}
      ]
  end

  defp check_sequence_flow_target(%SequenceFlow{id: id, target_ref: ref}, node_ids) do
    if blank?(ref) or MapSet.member?(node_ids, ref),
      do: [],
      else: [
        {:dangling_target_ref, "SequenceFlow '#{id}' references unknown target node '#{ref}'"}
      ]
  end

  # ---------------------------------------------------------------------------
  # Orphan node checks
  # ---------------------------------------------------------------------------

  defp check_orphan_nodes(%BpmnProcess{} = process) do
    sequence_flow_node_ids =
      process.sequence_flows
      |> Enum.flat_map(fn sequence_flow ->
        [sequence_flow.source_ref, sequence_flow.target_ref]
      end)
      |> MapSet.new()

    Enum.flat_map(process.flow_nodes, fn %FlowNode{} = node ->
      check_node_orphan(node, sequence_flow_node_ids)
    end)
  end

  defp check_node_orphan(%FlowNode{type: type}, _sequence_flow_node_ids)
       when type in [:start_event, :end_event, :boundary_event],
       do: []

  # Event Subprocesses have no incoming/outgoing sequence flows by definition
  # (they are triggered by their start event), so they are never orphans.
  defp check_node_orphan(
         %FlowNode{
           type: :sub_process,
           type_data: %FlowNodeData.SubProcess{triggered_by_event: true}
         },
         _sequence_flow_node_ids
       ),
       do: []

  defp check_node_orphan(
         %FlowNode{
           type: type,
           type_data: %{event_definition: %EventDefinition.Link{}}
         },
         _sequence_flow_node_ids
       )
       when type in [:intermediate_throw_event, :intermediate_catch_event],
       do: []

  defp check_node_orphan(%FlowNode{is_for_compensation: true}, _sequence_flow_node_ids),
    do: []

  defp check_node_orphan(%FlowNode{id: id, type: type}, sequence_flow_node_ids) do
    if MapSet.member?(sequence_flow_node_ids, id),
      do: [],
      else: [{:orphan_node, "#{type_label(type)} '#{id}' is not connected to any sequence flow"}]
  end

  # ---------------------------------------------------------------------------
  # Start/end flow direction checks
  # ---------------------------------------------------------------------------

  defp check_start_end_flow_direction(%BpmnProcess{} = process) do
    sequence_flow_targets =
      MapSet.new(process.sequence_flows, fn sequence_flow -> sequence_flow.target_ref end)

    sequence_flow_sources =
      MapSet.new(process.sequence_flows, fn sequence_flow -> sequence_flow.source_ref end)

    Enum.flat_map(process.flow_nodes, fn %FlowNode{} = node ->
      check_flow_direction(node, sequence_flow_targets, sequence_flow_sources)
    end)
  end

  defp check_flow_direction(
         %FlowNode{id: id, type: :start_event},
         sequence_flow_targets,
         _sequence_flow_sources
       ) do
    if MapSet.member?(sequence_flow_targets, id),
      do: [{:start_has_incoming, "StartEvent '#{id}' must not have incoming sequence flows"}],
      else: []
  end

  defp check_flow_direction(
         %FlowNode{id: id, type: :end_event},
         _sequence_flow_targets,
         sequence_flow_sources
       ) do
    if MapSet.member?(sequence_flow_sources, id),
      do: [{:end_has_outgoing, "EndEvent '#{id}' must not have outgoing sequence flows"}],
      else: []
  end

  defp check_flow_direction(_, _, _), do: []

  # ---------------------------------------------------------------------------
  # Data object reference checks
  # ---------------------------------------------------------------------------

  defp check_data_object_refs(%BpmnProcess{} = process) do
    do_ids = MapSet.new(process.data_objects, fn obj -> obj.id end)

    Enum.flat_map(process.data_object_references, fn ref ->
      if is_nil(ref.data_object_ref) or MapSet.member?(do_ids, ref.data_object_ref) do
        []
      else
        [
          {:dangling_data_object_ref,
           "DataObjectReference '#{ref.id}' references unknown DataObject '#{ref.data_object_ref}'"}
        ]
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Data association reference checks (DOA target_ref, DIA source_ref)
  # ---------------------------------------------------------------------------

  defp check_data_association_refs(%BpmnProcess{} = process) do
    do_ref_ids = MapSet.new(process.data_object_references, fn ref -> ref.id end)

    Enum.flat_map(process.flow_nodes, fn %FlowNode{id: node_id, type: type} = node ->
      label = type_label(type)

      doa_errors =
        Enum.flat_map(node.data_output_associations, fn assoc ->
          validate_doa_ref(assoc, do_ref_ids, label, node_id)
        end)

      dia_errors =
        Enum.flat_map(node.data_input_associations, fn assoc ->
          validate_dia_ref(assoc, do_ref_ids, label, node_id)
        end)

      doa_errors ++ dia_errors
    end)
  end

  defp validate_doa_ref(%{target_ref: ref} = assoc, _refs, label, node_id)
       when is_nil(ref) or ref == "" do
    [
      {:missing_doa_target_ref,
       "#{label} '#{node_id}' has a DataOutputAssociation '#{assoc.id}' " <>
         "missing required targetRef"}
    ]
  end

  defp validate_doa_ref(%{target_ref: ref} = assoc, do_ref_ids, label, node_id) do
    if MapSet.member?(do_ref_ids, ref) do
      []
    else
      [
        {:dangling_doa_target_ref,
         "#{label} '#{node_id}' has a DataOutputAssociation '#{assoc.id}' " <>
           "with targetRef='#{ref}' which does not match any DataObjectReference"}
      ]
    end
  end

  defp validate_dia_ref(%{source_ref: ref}, _refs, _label, _node_id)
       when is_nil(ref) or ref == "" do
    []
  end

  defp validate_dia_ref(%{source_ref: ref} = assoc, do_ref_ids, label, node_id) do
    if MapSet.member?(do_ref_ids, ref) do
      []
    else
      [
        {:dangling_dia_source_ref,
         "#{label} '#{node_id}' has a DataInputAssociation '#{assoc.id}' " <>
           "with sourceRef='#{ref}' which does not match any DataObjectReference"}
      ]
    end
  end

  # ---------------------------------------------------------------------------
  # Value contract schema validation
  # ---------------------------------------------------------------------------

  defp check_value_contract_schemas(%BpmnProcess{} = process) do
    Enum.flat_map(process.data_objects, fn obj ->
      case obj.value_contract do
        nil ->
          []

        schema when is_map(schema) ->
          try do
            _resolved = ExJsonSchema.Schema.resolve(schema)
            []
          rescue
            _ ->
              [
                {:invalid_value_contract,
                 "DataObject '#{obj.id}' has an invalid evil:valueContract JSON Schema"}
              ]
          end

        _ ->
          [
            {:invalid_value_contract,
             "DataObject '#{obj.id}' has an invalid evil:valueContract (must be a JSON object)"}
          ]
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Global reference checks (messages, signals, errors, escalations)
  # ---------------------------------------------------------------------------

  defp check_global_refs(%BpmnProcess{} = process, %Definitions{} = definitions) do
    id_sets = %{
      messages: MapSet.new(definitions.messages, fn m -> m.id end),
      signals: MapSet.new(definitions.signals, fn s -> s.id end),
      errors: MapSet.new(definitions.errors, fn e -> e.id end),
      escalations: MapSet.new(definitions.escalations, fn e -> e.id end)
    }

    Enum.flat_map(process.flow_nodes, fn %FlowNode{id: node_id, type: type, type_data: type_data} ->
      check_event_def_refs(type_data, node_id, type, id_sets) ++
        check_task_message_refs(type_data, node_id, type, id_sets.messages)
    end)
  end

  defp check_event_def_refs(type_data, node_id, type, id_sets) do
    case get_event_definition(type_data) do
      %EventDefinition.Message{message_ref: ref} when ref != nil ->
        check_global_ref(
          ref,
          id_sets.messages,
          :dangling_message_ref,
          node_id,
          type,
          "messageRef",
          "MessageDefinition"
        )

      %EventDefinition.Signal{signal_ref: ref} when ref != nil ->
        check_global_ref(
          ref,
          id_sets.signals,
          :dangling_signal_ref,
          node_id,
          type,
          "signalRef",
          "SignalDefinition"
        )

      %EventDefinition.Error{error_ref: ref} when ref != nil ->
        check_global_ref(
          ref,
          id_sets.errors,
          :dangling_error_ref,
          node_id,
          type,
          "errorRef",
          "ErrorDefinition"
        )

      %EventDefinition.Escalation{escalation_ref: ref} when ref != nil ->
        check_global_ref(
          ref,
          id_sets.escalations,
          :dangling_escalation_ref,
          node_id,
          type,
          "escalationRef",
          "EscalationDefinition"
        )

      _ ->
        []
    end
  end

  defp check_task_message_refs(
         %FlowNodeData.SendTask{message_ref: ref},
         node_id,
         type,
         message_ids
       )
       when ref != nil do
    check_global_ref(
      ref,
      message_ids,
      :dangling_message_ref,
      node_id,
      type,
      "messageRef",
      "MessageDefinition"
    )
  end

  defp check_task_message_refs(
         %FlowNodeData.ReceiveTask{message_ref: ref},
         node_id,
         type,
         message_ids
       )
       when ref != nil do
    check_global_ref(
      ref,
      message_ids,
      :dangling_message_ref,
      node_id,
      type,
      "messageRef",
      "MessageDefinition"
    )
  end

  defp check_task_message_refs(_, _, _, _), do: []

  defp check_global_ref(ref, id_set, code, node_id, type, attr_name, target_type) do
    if MapSet.member?(id_set, ref) do
      []
    else
      [
        {code,
         "#{type_label(type)} '#{node_id}' has #{attr_name}='#{ref}' " <>
           "which does not match any declared #{target_type}"}
      ]
    end
  end

  # ---------------------------------------------------------------------------
  # Event definition position checks
  # ---------------------------------------------------------------------------

  @valid_event_positions %{
    FlowNodeData.StartEvent => [
      EventDefinition.None,
      EventDefinition.Message,
      EventDefinition.Signal,
      EventDefinition.Timer,
      EventDefinition.Conditional
    ],
    FlowNodeData.EndEvent => [
      EventDefinition.None,
      EventDefinition.Message,
      EventDefinition.Signal,
      EventDefinition.Error,
      EventDefinition.Escalation,
      EventDefinition.Terminate,
      EventDefinition.Cancel,
      EventDefinition.Compensation
    ],
    FlowNodeData.IntermediateCatchEvent => [
      EventDefinition.None,
      EventDefinition.Message,
      EventDefinition.Signal,
      EventDefinition.Timer,
      EventDefinition.Conditional,
      EventDefinition.Link
    ],
    FlowNodeData.IntermediateThrowEvent => [
      EventDefinition.None,
      EventDefinition.Message,
      EventDefinition.Signal,
      EventDefinition.Escalation,
      EventDefinition.Compensation,
      EventDefinition.Link
    ],
    FlowNodeData.BoundaryEvent => [
      EventDefinition.None,
      EventDefinition.Message,
      EventDefinition.Signal,
      EventDefinition.Error,
      EventDefinition.Timer,
      EventDefinition.Escalation,
      EventDefinition.Conditional,
      EventDefinition.Compensation,
      EventDefinition.Cancel
    ]
  }

  defp check_event_definition_positions(%BpmnProcess{} = process) do
    Enum.flat_map(process.flow_nodes, fn %FlowNode{id: node_id, type: type, type_data: type_data} ->
      validate_event_position(node_id, type, type_data)
    end)
  end

  defp validate_event_position(node_id, type, type_data) do
    position_mod = type_data.__struct__

    case {Map.get(@valid_event_positions, position_mod), get_event_definition(type_data)} do
      {nil, _} ->
        []

      {_, nil} ->
        []

      {valid_definitions, event_def} ->
        check_position_match(node_id, type, event_def, valid_definitions)
    end
  end

  defp check_position_match(node_id, type, event_def, valid_definitions) do
    def_mod = event_def.__struct__

    if def_mod in valid_definitions do
      []
    else
      def_name = def_mod |> Module.split() |> List.last()

      [
        {:invalid_event_position,
         "#{type_label(type)} '#{node_id}' cannot use #{def_name} — " <>
           "this event definition type is not allowed in this position"}
      ]
    end
  end

  # ---------------------------------------------------------------------------
  # Type-specific completeness checks
  # ---------------------------------------------------------------------------

  defp check_flow_node_completeness(%BpmnProcess{} = process, %Definitions{} = definitions) do
    node_ids = MapSet.new(process.flow_nodes, fn %FlowNode{id: id} -> id end)

    Enum.flat_map(process.flow_nodes, fn %FlowNode{id: id, type: type, type_data: type_data} ->
      validate_type_data(id, type, type_data, node_ids, definitions)
    end)
  end

  # ---------------------------------------------------------------------------
  # Embedded subprocess structural checks
  # ---------------------------------------------------------------------------

  defp validate_subprocess_structure(
         subprocess_id,
         %FlowNodeData.SubProcess{} = data,
         %Definitions{} = definitions
       ) do
    scope_label = "[in SubProcess '#{subprocess_id}'] "
    validate_inner_scope_structure(subprocess_id, data, definitions, scope_label)
  end

  # Event Subprocess structural validation (ESP-D7). Runs the same inner-scope
  # checks as an embedded subprocess, then adds ESP-specific start-event rules.
  # The "no incoming/outgoing sequence flow on the shell" rule is enforced at the
  # containing-scope level by `check_event_subprocess_shell_flows/1`.
  defp validate_event_subprocess_structure(
         subprocess_id,
         %FlowNodeData.SubProcess{} = data,
         %Definitions{} = definitions
       ) do
    scope_label = "[in Event SubProcess '#{subprocess_id}'] "

    List.flatten([
      validate_inner_scope_structure(subprocess_id, data, definitions, scope_label),
      check_event_subprocess_start_event(subprocess_id, data, scope_label)
    ])
  end

  defp validate_inner_scope_structure(
         subprocess_id,
         %FlowNodeData.SubProcess{} = data,
         %Definitions{} = definitions,
         scope_label
       ) do
    inner_node_ids = MapSet.new(data.flow_nodes, & &1.id)

    inner_scope_as_process = %BpmnProcess{
      id: subprocess_id,
      flow_nodes: data.flow_nodes,
      sequence_flows: data.sequence_flows
    }

    List.flatten([
      check_subprocess_essential_properties(scope_label, data),
      check_subprocess_sequence_flow_refs(scope_label, data.sequence_flows, inner_node_ids),
      check_subprocess_orphan_nodes(scope_label, data.flow_nodes, data.sequence_flows),
      check_event_based_gateways(inner_scope_as_process),
      Enum.flat_map(data.flow_nodes, fn %FlowNode{id: id, type: type, type_data: type_data} ->
        validate_type_data(id, type, type_data, inner_node_ids, definitions, scope_label)
      end)
    ])
  end

  # ESP-D7 + COMP-D5: exactly one start event; the start must be a supported
  # typed trigger (message/signal/timer/error/escalation/conditional/compensation),
  # never None/other; an error start must be interrupting.
  defp check_event_subprocess_start_event(
         subprocess_id,
         %FlowNodeData.SubProcess{flow_nodes: flow_nodes},
         scope_label
       ) do
    start_events = Enum.filter(flow_nodes, &(&1.type == :start_event))

    case start_events do
      [] ->
        [
          {:event_subprocess_no_start_event,
           scope_label <>
             "Event SubProcess '#{subprocess_id}' must have exactly one start event, but has none"}
        ]

      [start] ->
        check_esp_start_event_type(subprocess_id, start, scope_label)

      many ->
        [
          {:event_subprocess_multiple_start_events,
           scope_label <>
             "Event SubProcess '#{subprocess_id}' must have exactly one start event, " <>
             "but has #{length(many)}"}
        ]
    end
  end

  defp check_esp_start_event_type(
         subprocess_id,
         %FlowNode{
           id: start_id,
           type_data: %FlowNodeData.StartEvent{
             event_definition: event_definition,
             is_interrupting: is_interrupting
           }
         },
         scope_label
       ) do
    typed_error =
      if esp_start_allowed?(event_definition) do
        []
      else
        [
          {:event_subprocess_untyped_start,
           scope_label <>
             "Start event '#{start_id}' of Event SubProcess '#{subprocess_id}' must be a " <>
             "supported typed trigger (message, signal, timer, error, escalation, " <>
             "conditional, or compensation); a plain/none or unsupported start is not allowed"}
        ]
      end

    interrupt_error =
      case event_definition do
        %EventDefinition.Error{} when is_interrupting == false ->
          [
            {:event_subprocess_error_start_must_interrupt,
             scope_label <>
               "Error start event '#{start_id}' of Event SubProcess '#{subprocess_id}' must be " <>
               "interrupting (isInterrupting must not be false)"}
          ]

        _ ->
          []
      end

    typed_error ++ interrupt_error
  end

  defp esp_start_allowed?(%EventDefinition.Message{}), do: true
  defp esp_start_allowed?(%EventDefinition.Signal{}), do: true
  defp esp_start_allowed?(%EventDefinition.Timer{}), do: true
  defp esp_start_allowed?(%EventDefinition.Error{}), do: true
  defp esp_start_allowed?(%EventDefinition.Escalation{}), do: true
  defp esp_start_allowed?(%EventDefinition.Conditional{}), do: true
  defp esp_start_allowed?(%EventDefinition.Compensation{}), do: true
  defp esp_start_allowed?(_), do: false

  defp check_subprocess_essential_properties(scope_label, %FlowNodeData.SubProcess{} = data) do
    node_errors =
      Enum.flat_map(data.flow_nodes, fn %FlowNode{id: id, type: type} ->
        if blank?(id),
          do: [
            {:missing_node_id,
             scope_label <> "#{type_label(type)} is missing required property: id"}
          ],
          else: []
      end)

    flow_errors =
      Enum.flat_map(data.sequence_flows, fn sequence_flow ->
        check_subprocess_sequence_flow_essential_props(scope_label, sequence_flow)
      end)

    node_errors ++ flow_errors
  end

  defp check_subprocess_sequence_flow_essential_props(scope_label, %SequenceFlow{} = sequence_flow) do
    missing = collect_missing_sequence_flow_props(sequence_flow)

    if missing == [] do
      []
    else
      label =
        if blank?(sequence_flow.id),
          do: "SequenceFlow (unknown)",
          else: "SequenceFlow '#{sequence_flow.id}'"

      [
        {:incomplete_sequence_flow,
         scope_label <>
           "#{label} is missing required properties: #{Enum.join(missing, ", ")}"}
      ]
    end
  end

  defp check_subprocess_sequence_flow_refs(scope_label, sequence_flows, inner_node_ids) do
    Enum.flat_map(sequence_flows, fn %SequenceFlow{} = sequence_flow ->
      check_subprocess_sequence_flow_source(scope_label, sequence_flow, inner_node_ids) ++
        check_subprocess_sequence_flow_target(scope_label, sequence_flow, inner_node_ids)
    end)
  end

  defp check_subprocess_sequence_flow_source(
         scope_label,
         %SequenceFlow{id: id, source_ref: source_ref},
         inner_node_ids
       ) do
    if blank?(source_ref) or MapSet.member?(inner_node_ids, source_ref),
      do: [],
      else: [
        {:dangling_source_ref,
         scope_label <>
           "SequenceFlow '#{id}' references unknown source node '#{source_ref}'"}
      ]
  end

  defp check_subprocess_sequence_flow_target(
         scope_label,
         %SequenceFlow{id: id, target_ref: target_ref},
         inner_node_ids
       ) do
    if blank?(target_ref) or MapSet.member?(inner_node_ids, target_ref),
      do: [],
      else: [
        {:dangling_target_ref,
         scope_label <>
           "SequenceFlow '#{id}' references unknown target node '#{target_ref}'"}
      ]
  end

  defp check_subprocess_orphan_nodes(scope_label, flow_nodes, sequence_flows) do
    sequence_flow_node_ids =
      sequence_flows
      |> Enum.flat_map(fn sequence_flow ->
        [sequence_flow.source_ref, sequence_flow.target_ref]
      end)
      |> MapSet.new()

    Enum.flat_map(flow_nodes, fn %FlowNode{} = node ->
      check_subprocess_node_orphan(scope_label, node, sequence_flow_node_ids)
    end)
  end

  defp check_subprocess_node_orphan(_scope_label, %FlowNode{type: type}, _sequence_flow_node_ids)
       when type in [:start_event, :end_event, :boundary_event],
       do: []

  defp check_subprocess_node_orphan(
         _scope_label,
         %FlowNode{
           type: :sub_process,
           type_data: %FlowNodeData.SubProcess{triggered_by_event: true}
         },
         _sequence_flow_node_ids
       ),
       do: []

  defp check_subprocess_node_orphan(
         _scope_label,
         %FlowNode{
           type: type,
           type_data: %{event_definition: %EventDefinition.Link{}}
         },
         _sequence_flow_node_ids
       )
       when type in [:intermediate_throw_event, :intermediate_catch_event],
       do: []

  defp check_subprocess_node_orphan(
         _scope_label,
         %FlowNode{is_for_compensation: true},
         _sequence_flow_node_ids
       ),
       do: []

  defp check_subprocess_node_orphan(
         scope_label,
         %FlowNode{id: id, type: type},
         sequence_flow_node_ids
       ) do
    if MapSet.member?(sequence_flow_node_ids, id),
      do: [],
      else: [
        {:orphan_node,
         scope_label <>
           "#{type_label(type)} '#{id}' is not connected to any sequence flow"}
      ]
  end

  # ---------------------------------------------------------------------------
  # Cross-boundary sequence flow checks (parent scope vs inner subprocess nodes)
  # ---------------------------------------------------------------------------

  defp check_cross_boundary_flows(%BpmnProcess{} = process) do
    parent_node_ids = MapSet.new(process.flow_nodes, & &1.id)
    all_inner_node_ids = collect_all_inner_node_ids(process.flow_nodes)

    parent_errors =
      Enum.flat_map(process.sequence_flows, fn sequence_flow ->
        check_parent_flow_cross_boundary(sequence_flow, all_inner_node_ids)
      end)

    inner_errors = check_inner_flows_cross_boundary(process.flow_nodes, parent_node_ids)

    parent_errors ++ inner_errors
  end

  defp collect_all_inner_node_ids(flow_nodes) do
    Enum.reduce(flow_nodes, MapSet.new(), fn %FlowNode{type_data: type_data}, accumulated_ids ->
      case type_data do
        %FlowNodeData.SubProcess{flow_nodes: inner_flow_nodes} ->
          direct_inner_ids = MapSet.new(inner_flow_nodes, & &1.id)
          nested_inner_ids = collect_all_inner_node_ids(inner_flow_nodes)

          accumulated_ids
          |> MapSet.union(direct_inner_ids)
          |> MapSet.union(nested_inner_ids)

        _ ->
          accumulated_ids
      end
    end)
  end

  defp check_parent_flow_cross_boundary(
         %SequenceFlow{id: id, source_ref: source_ref, target_ref: target_ref},
         all_inner_node_ids
       ) do
    source_error =
      if not blank?(source_ref) and MapSet.member?(all_inner_node_ids, source_ref) do
        [
          {:cross_boundary_flow,
           "SequenceFlow '#{id}' references inner subprocess node '#{source_ref}' from parent scope"}
        ]
      else
        []
      end

    target_error =
      if not blank?(target_ref) and MapSet.member?(all_inner_node_ids, target_ref) do
        [
          {:cross_boundary_flow,
           "SequenceFlow '#{id}' references inner subprocess node '#{target_ref}' from parent scope"}
        ]
      else
        []
      end

    source_error ++ target_error
  end

  defp check_inner_flows_cross_boundary(flow_nodes, parent_node_ids) do
    Enum.flat_map(flow_nodes, fn %FlowNode{type_data: type_data} ->
      check_subprocess_inner_flows_cross_boundary(type_data, parent_node_ids)
    end)
  end

  defp check_subprocess_inner_flows_cross_boundary(
         %FlowNodeData.SubProcess{
           flow_nodes: inner_flow_nodes,
           sequence_flows: inner_sequence_flows
         },
         parent_node_ids
       ) do
    flow_errors =
      Enum.flat_map(inner_sequence_flows, fn sequence_flow ->
        check_inner_flow_cross_boundary(sequence_flow, parent_node_ids)
      end)

    nested_errors = check_inner_flows_cross_boundary(inner_flow_nodes, parent_node_ids)

    flow_errors ++ nested_errors
  end

  defp check_subprocess_inner_flows_cross_boundary(_type_data, _parent_node_ids), do: []

  defp check_inner_flow_cross_boundary(
         %SequenceFlow{id: id, source_ref: source_ref, target_ref: target_ref},
         parent_node_ids
       ) do
    source_error =
      if not blank?(source_ref) and MapSet.member?(parent_node_ids, source_ref) do
        [
          {:cross_boundary_flow,
           "SequenceFlow '#{id}' references parent-scope node '#{source_ref}' from inside a subprocess"}
        ]
      else
        []
      end

    target_error =
      if not blank?(target_ref) and MapSet.member?(parent_node_ids, target_ref) do
        [
          {:cross_boundary_flow,
           "SequenceFlow '#{id}' references parent-scope node '#{target_ref}' from inside a subprocess"}
        ]
      else
        []
      end

    source_error ++ target_error
  end

  # ---------------------------------------------------------------------------
  # Event Subprocess shell flow checks (ESP-D7: no incoming/outgoing flows)
  # ---------------------------------------------------------------------------

  # An Event Subprocess shell is triggered by its start event and is NOT
  # connected to the sequence flow of its containing scope. This check scans
  # every scope (top-level process + each nested subprocess inner scope) and
  # rejects any sequence flow that references an ESP shell node id.
  defp check_event_subprocess_shell_flows(%BpmnProcess{} = process) do
    check_scope_event_subprocess_flows(process.flow_nodes, process.sequence_flows)
  end

  defp check_scope_event_subprocess_flows(flow_nodes, sequence_flows) do
    event_subprocess_ids =
      flow_nodes
      |> Enum.filter(fn
        %FlowNode{type: :sub_process, type_data: %FlowNodeData.SubProcess{triggered_by_event: true}} ->
          true

        _ ->
          false
      end)
      |> MapSet.new(& &1.id)

    own_errors =
      Enum.flat_map(sequence_flows, fn %SequenceFlow{} = sequence_flow ->
        check_event_subprocess_flow_endpoints(sequence_flow, event_subprocess_ids)
      end)

    nested_errors =
      Enum.flat_map(flow_nodes, fn %FlowNode{type_data: type_data} ->
        case type_data do
          %FlowNodeData.SubProcess{flow_nodes: inner_flow_nodes, sequence_flows: inner_flows} ->
            check_scope_event_subprocess_flows(inner_flow_nodes, inner_flows)

          _ ->
            []
        end
      end)

    own_errors ++ nested_errors
  end

  defp check_event_subprocess_flow_endpoints(
         %SequenceFlow{id: id, source_ref: source_ref, target_ref: target_ref},
         event_subprocess_ids
       ) do
    source_error =
      if not blank?(source_ref) and MapSet.member?(event_subprocess_ids, source_ref) do
        [
          {:event_subprocess_has_sequence_flow,
           "SequenceFlow '#{id}' has source '#{source_ref}', an Event SubProcess, which must " <>
             "have no incoming or outgoing sequence flows"}
        ]
      else
        []
      end

    target_error =
      if not blank?(target_ref) and MapSet.member?(event_subprocess_ids, target_ref) do
        [
          {:event_subprocess_has_sequence_flow,
           "SequenceFlow '#{id}' has target '#{target_ref}', an Event SubProcess, which must " <>
             "have no incoming or outgoing sequence flows"}
        ]
      else
        []
      end

    source_error ++ target_error
  end

  # ---------------------------------------------------------------------------
  # Global flow-node ID uniqueness (process + nested subprocess scopes)
  # ---------------------------------------------------------------------------

  # A flow-node ID must be unique across the entire process tree — the top-level
  # process AND every embedded/event/transactional subprocess inner scope,
  # recursively. Duplicate IDs make start-event resolution and subprocess scoping
  # ambiguous (see the isolation invariant in
  # `EvilEngine.Execution.ProcessInstance.resolve_start_event/2`): an inner Start
  # Event sharing an ID with a top-level Start Event could otherwise blur the
  # boundary between externally-addressable and scope-owned nodes.
  defp check_unique_flow_node_ids(%BpmnProcess{} = process) do
    process.flow_nodes
    |> collect_all_flow_node_ids()
    |> Enum.frequencies()
    |> Enum.filter(fn {_id, count} -> count > 1 end)
    |> Enum.sort_by(fn {id, _count} -> id end)
    |> Enum.map(fn {id, count} ->
      {:duplicate_flow_node_id,
       "Flow node id '#{id}' is declared #{count} times across the process and its " <>
         "subprocess scopes. Flow node ids must be unique within a process tree so that " <>
         "start-event resolution and subprocess scoping remain unambiguous."}
    end)
  end

  defp collect_all_flow_node_ids(flow_nodes) do
    flow_nodes
    |> Enum.flat_map(fn %FlowNode{id: id, type_data: type_data} ->
      nested =
        case type_data do
          %FlowNodeData.SubProcess{flow_nodes: inner_flow_nodes} ->
            collect_all_flow_node_ids(inner_flow_nodes)

          _ ->
            []
        end

      [id | nested]
    end)
    |> Enum.reject(&blank?/1)
  end

  # --- Activities ---

  defp validate_type_data(id, type, type_data, node_ids, definitions) do
    validate_type_data(id, type, type_data, node_ids, definitions, "")
  end

  defp validate_type_data(
         id,
         type,
         %FlowNodeData.CallActivity{} = data,
         _node_ids,
         _definitions,
         scope_label
       ) do
    missing =
      []
      |> maybe_add(blank?(data.called_element), "calledElement")

    missing_flow_node_props_error(id, type, missing, scope_label)
  end

  defp validate_type_data(
         id,
         type,
         %FlowNodeData.ServiceTask{} = data,
         _node_ids,
         _definitions,
         scope_label
       ) do
    missing =
      []
      |> maybe_add(blank?(data.implementation), "implementation")

    missing_flow_node_props_error(id, type, missing, scope_label)
  end

  defp validate_type_data(
         id,
         type,
         %FlowNodeData.SendTask{} = data,
         _node_ids,
         _definitions,
         scope_label
       ) do
    missing =
      []
      |> maybe_add(blank?(data.message_ref), "messageRef")

    missing_flow_node_props_error(id, type, missing, scope_label)
  end

  defp validate_type_data(
         id,
         type,
         %FlowNodeData.ReceiveTask{} = data,
         _node_ids,
         _definitions,
         scope_label
       ) do
    missing =
      []
      |> maybe_add(blank?(data.message_ref), "messageRef")

    missing_flow_node_props_error(id, type, missing, scope_label)
  end

  defp validate_type_data(
         id,
         type,
         %FlowNodeData.ScriptTask{} = data,
         _node_ids,
         _definitions,
         scope_label
       ) do
    if blank?(data.script) and blank?(data.script_ref) do
      [
        {:incomplete_flow_node,
         scope_label <>
           "#{type_label(type)} '#{id}' is missing required properties: " <>
             "script or scriptRef (at least one must be provided)"}
      ]
    else
      []
    end
  end

  @valid_brt_implementations ["feel", "dmn"]

  defp validate_type_data(
         id,
         type,
         %FlowNodeData.BusinessRuleTask{} = data,
         _node_ids,
         _definitions,
         scope_label
       ) do
    label = type_label(type)

    cond do
      blank?(data.implementation) ->
        [
          {:incomplete_flow_node,
           scope_label <>
             "#{label} '#{id}' is missing required property: " <>
               "implementation (must be one of: feel, dmn)"}
        ]

      data.implementation not in @valid_brt_implementations ->
        [
          {:invalid_brt_implementation,
           scope_label <>
             "#{label} '#{id}' has unrecognized implementation='#{data.implementation}' " <>
               "(must be one of: feel, dmn)"}
        ]

      true ->
        check_brt_mode_properties(id, label, data, scope_label)
    end
  end

  defp validate_type_data(
         id,
         _type,
         %FlowNodeData.SubProcess{triggered_by_event: false} = data,
         _node_ids,
         definitions,
         _scope_label
       ) do
    validate_subprocess_structure(id, data, definitions)
  end

  defp validate_type_data(
         id,
         _type,
         %FlowNodeData.SubProcess{triggered_by_event: true} = data,
         _node_ids,
         definitions,
         _scope_label
       ) do
    validate_event_subprocess_structure(id, data, definitions)
  end

  # --- Gateways ---

  defp validate_type_data(
         _id,
         _type,
         %FlowNodeData.ComplexGateway{},
         _node_ids,
         _definitions,
         _scope_label
       ) do
    # Complex Gateway structural rules (mixed rejection, split flow
    # conditionality, join activationCondition) are enforced in
    # `check_complex_gateways/1`, which has access to the process's
    # sequence flows to distinguish split from join. `activationCondition`
    # is required for JOINs only, never for splits (see CG-D1/CG-D2).
    []
  end

  # --- Boundary events ---

  defp validate_type_data(
         id,
         type,
         %FlowNodeData.BoundaryEvent{} = data,
         node_ids,
         _definitions,
         scope_label
       ) do
    missing =
      []
      |> maybe_add(blank?(data.attached_to_ref), "attachedToRef")

    dangling =
      if not blank?(data.attached_to_ref) and not MapSet.member?(node_ids, data.attached_to_ref) do
        [
          {:boundary_event_dangling_attached_to,
           scope_label <>
             "#{type_label(type)} '#{id}' has attachedToRef='#{data.attached_to_ref}' " <>
               "which does not match any FlowNode in this scope"}
        ]
      else
        []
      end

    event_errors =
      validate_event_definition_completeness(id, type, data.event_definition, scope_label)

    missing_flow_node_props_error(id, type, missing, scope_label) ++ dangling ++ event_errors
  end

  # --- Events (position structs with event_definition) ---

  defp validate_type_data(
         id,
         type,
         %FlowNodeData.StartEvent{event_definition: event_definition},
         _node_ids,
         _definitions,
         scope_label
       ) do
    validate_event_definition_completeness(id, type, event_definition, scope_label)
  end

  defp validate_type_data(
         id,
         type,
         %FlowNodeData.EndEvent{event_definition: event_definition},
         _node_ids,
         _definitions,
         scope_label
       ) do
    validate_event_definition_completeness(id, type, event_definition, scope_label)
  end

  defp validate_type_data(
         id,
         type,
         %FlowNodeData.IntermediateCatchEvent{event_definition: event_definition},
         _node_ids,
         _definitions,
         scope_label
       ) do
    validate_event_definition_completeness(id, type, event_definition, scope_label)
  end

  defp validate_type_data(
         id,
         type,
         %FlowNodeData.IntermediateThrowEvent{event_definition: event_definition},
         _node_ids,
         _definitions,
         scope_label
       ) do
    validate_event_definition_completeness(id, type, event_definition, scope_label)
  end

  # --- Everything else (Task, UserTask, ManualTask, gateways without required fields) ---

  defp validate_type_data(_id, _type, _type_data, _node_ids, _definitions, _scope_label), do: []

  # ---------------------------------------------------------------------------
  # BRT mode-specific property checks (extracted to keep validate_type_data lean)
  # ---------------------------------------------------------------------------

  defp check_brt_mode_properties(id, label, %{implementation: "feel", script: script}, scope_label) do
    if blank?(script) do
      [
        {:incomplete_flow_node,
         scope_label <>
           "#{label} '#{id}' has implementation='feel' but is missing " <>
             "required property: script (<bpmn:script> child element)"}
      ]
    else
      []
    end
  end

  defp check_brt_mode_properties(
         id,
         label,
         %{implementation: "dmn", decision_ref: decision_ref},
         scope_label
       ) do
    if blank?(decision_ref) do
      [
        {:incomplete_flow_node,
         scope_label <>
           "#{label} '#{id}' has implementation='dmn' but is missing " <>
             "required property: decisionRef (evil:decisionRef)"}
      ]
    else
      []
    end
  end

  # ---------------------------------------------------------------------------
  # Event definition completeness checks
  # ---------------------------------------------------------------------------

  defp validate_event_definition_completeness(
         id,
         type,
         %EventDefinition.Message{} = event_definition,
         scope_label
       ) do
    missing =
      []
      |> maybe_add(blank?(event_definition.message_ref), "messageRef")

    missing_event_definition_props_error(id, type, missing, "MessageEventDefinition", scope_label)
  end

  defp validate_event_definition_completeness(
         id,
         type,
         %EventDefinition.Signal{} = event_definition,
         scope_label
       ) do
    missing =
      []
      |> maybe_add(blank?(event_definition.signal_ref), "signalRef")

    missing_event_definition_props_error(id, type, missing, "SignalEventDefinition", scope_label)
  end

  defp validate_event_definition_completeness(
         id,
         type,
         %EventDefinition.Timer{} = event_definition,
         scope_label
       ) do
    has_any =
      not blank?(event_definition.time_date) or not blank?(event_definition.time_duration) or
        not blank?(event_definition.time_cycle)

    if has_any do
      []
    else
      [
        {:incomplete_event_definition,
         scope_label <>
           "#{type_label(type)} '#{id}' has a TimerEventDefinition that is missing required properties: " <>
             "timeDate, timeDuration, or timeCycle (exactly one must be provided)"}
      ]
    end
  end

  defp validate_event_definition_completeness(
         id,
         type,
         %EventDefinition.Conditional{} = event_definition,
         scope_label
       ) do
    missing =
      []
      |> maybe_add(blank?(event_definition.condition_expression), "condition")

    missing_event_definition_props_error(
      id,
      type,
      missing,
      "ConditionalEventDefinition",
      scope_label
    )
  end

  defp validate_event_definition_completeness(
         id,
         type,
         %EventDefinition.Link{} = event_definition,
         scope_label
       ) do
    missing =
      []
      |> maybe_add(blank?(event_definition.link_name), "name")

    missing_event_definition_props_error(id, type, missing, "LinkEventDefinition", scope_label)
  end

  # Error, Escalation, Compensation, Terminate, Cancel, None — no mandatory fields
  defp validate_event_definition_completeness(_id, _type, _event_definition, _scope_label), do: []

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp get_event_definition(%{event_definition: ed}), do: ed
  defp get_event_definition(_), do: nil

  # ---------------------------------------------------------------------------
  # Event-Based Gateway checks
  # ---------------------------------------------------------------------------

  defp check_event_based_gateways(%BpmnProcess{} = process) do
    node_index = Map.new(process.flow_nodes, &{&1.id, &1})

    process.flow_nodes
    |> Enum.filter(&(&1.type == :event_based_gateway))
    |> Enum.flat_map(&check_single_event_based_gateway(&1, process, node_index))
  end

  defp check_single_event_based_gateway(gateway, process, node_index) do
    outgoing_flows =
      Enum.filter(process.sequence_flows, &(&1.source_ref == gateway.id))

    outgoing_flows
    |> Enum.flat_map(fn flow ->
      case Map.get(node_index, flow.target_ref) do
        %FlowNode{type: :receive_task} = target ->
          check_receive_task_has_no_boundaries(gateway, target, process)

        _ ->
          []
      end
    end)
  end

  defp check_receive_task_has_no_boundaries(gateway, receive_task, process) do
    has_boundary =
      Enum.any?(process.flow_nodes, fn
        %FlowNode{type: :boundary_event, type_data: %{attached_to_ref: host_id}}
        when host_id == receive_task.id ->
          true

        _ ->
          false
      end)

    if has_boundary do
      [
        {:event_based_gateway_receive_task_has_boundary,
         "EventBasedGateway '#{gateway.id}': Receive Task '#{receive_task.id}' must not have " <>
           "boundary events when used as an Event-Based Gateway target"}
      ]
    else
      []
    end
  end

  # ---------------------------------------------------------------------------
  # Complex Gateway checks
  # ---------------------------------------------------------------------------

  defp check_complex_gateways(%BpmnProcess{} = process) do
    per_gateway_violations =
      process.flow_nodes
      |> Enum.filter(&(&1.type == :complex_gateway))
      |> Enum.flat_map(&check_single_complex_gateway(&1, process))

    # Pairing / SESE well-formedness (CG-D5, CG-D10): every Complex Join must
    # pair to exactly one dominating Complex Split, and its region must be a
    # single-entry / single-exit interval that is disjoint from or strictly
    # nested inside every other region.
    per_gateway_violations ++ ComplexRegionAnalysis.region_violations(process)
  end

  defp check_single_complex_gateway(gateway, process) do
    incoming = Enum.filter(process.sequence_flows, &(&1.target_ref == gateway.id))
    outgoing = Enum.filter(process.sequence_flows, &(&1.source_ref == gateway.id))

    cond do
      length(incoming) > 1 and length(outgoing) > 1 ->
        [
          {:complex_gateway_mixed,
           "ComplexGateway '#{gateway.id}' is a mixed gateway (#{length(incoming)} incoming, " <>
             "#{length(outgoing)} outgoing). A Complex Gateway must be either a split " <>
             "(one incoming, many outgoing) or a join (many incoming, one outgoing), not both."}
        ]

      length(outgoing) > 1 ->
        check_complex_split_flows(gateway, outgoing)

      length(incoming) > 1 ->
        check_complex_join_activation_condition(gateway)

      true ->
        []
    end
  end

  defp check_complex_join_activation_condition(gateway) do
    activation_condition =
      case gateway.type_data do
        %FlowNodeData.ComplexGateway{activation_condition: condition} -> condition
        _ -> nil
      end

    if blank?(activation_condition) do
      [
        {:complex_gateway_join_missing_activation_condition,
         "ComplexGateway '#{gateway.id}' is a join (many incoming, one outgoing) and is " <>
           "missing required properties: activationCondition. A Complex Join fires when its " <>
           "activationCondition becomes true, so the condition is mandatory."}
      ]
    else
      []
    end
  end

  defp check_complex_split_flows(gateway, outgoing_flows) do
    Enum.flat_map(outgoing_flows, fn flow ->
      if blank?(flow.condition_expression) and not flow.is_default do
        [
          {:complex_gateway_unconditional_flow,
           "ComplexGateway '#{gateway.id}' has unconditional non-default outgoing flow " <>
             "'#{flow.id}'. Every outgoing flow of a Complex Split must carry a " <>
             "conditionExpression or be the gateway's default flow."}
        ]
      else
        []
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Transaction + Cancel scope checks (E2)
  # ---------------------------------------------------------------------------

  defp check_cancel_transaction_scope(%BpmnProcess{} = process) do
    do_check_cancel_scope(process.flow_nodes, false)
  end

  defp do_check_cancel_scope(flow_nodes, inside_transaction) do
    node_index = Map.new(flow_nodes, &{&1.id, &1})

    Enum.flat_map(flow_nodes, fn node ->
      check_cancel_scope_node(node, inside_transaction, node_index)
    end)
  end

  defp check_cancel_scope_node(%FlowNode{id: id, type: type, type_data: data}, inside_transaction, node_index) do
    cancel_end_errors = check_cancel_end_scope(id, type, data, inside_transaction)
    cancel_boundary_errors = check_cancel_boundary_host(id, type, data, node_index)
    inner_errors = check_cancel_scope_inner(data)

    cancel_end_errors ++ cancel_boundary_errors ++ inner_errors
  end

  defp check_cancel_end_scope(id, :end_event, %FlowNodeData.EndEvent{event_definition: %EventDefinition.Cancel{}}, false) do
    [
      {:cancel_end_outside_transaction,
       "EndEvent '#{id}' has a Cancel event definition but is not inside a Transaction subprocess. " <>
         "Cancel End Events are only valid inside a bpmn:transaction element."}
    ]
  end

  defp check_cancel_end_scope(_id, _type, _data, _inside_transaction), do: []

  defp check_cancel_boundary_host(id, :boundary_event, %FlowNodeData.BoundaryEvent{event_definition: %EventDefinition.Cancel{}, attached_to_ref: host_ref}, node_index) do
    host = Map.get(node_index, host_ref)

    if cancel_boundary_host_valid?(host) do
      []
    else
      [
        {:cancel_boundary_not_on_transaction,
         "BoundaryEvent '#{id}' has a Cancel event definition but its host '#{host_ref}' " <>
           "is not a Transaction subprocess. Cancel Boundary Events must be attached to a bpmn:transaction element."}
      ]
    end
  end

  defp check_cancel_boundary_host(_id, _type, _data, _node_index), do: []

  defp cancel_boundary_host_valid?(nil), do: false

  defp cancel_boundary_host_valid?(%FlowNode{type: :sub_process, type_data: %FlowNodeData.SubProcess{is_transaction: true}}),
    do: true

  defp cancel_boundary_host_valid?(_), do: false

  defp check_cancel_scope_inner(%FlowNodeData.SubProcess{flow_nodes: inner_nodes, is_transaction: is_tx}) do
    do_check_cancel_scope(inner_nodes, is_tx)
  end

  defp check_cancel_scope_inner(_), do: []

  defp check_nested_transactions(%BpmnProcess{} = process) do
    do_check_nested_transactions(process.flow_nodes)
  end

  defp do_check_nested_transactions(flow_nodes) do
    Enum.flat_map(flow_nodes, &check_nested_transactions_node/1)
  end

  defp check_nested_transactions_node(%FlowNode{id: id, type: :sub_process, type_data: %FlowNodeData.SubProcess{is_transaction: true, flow_nodes: inner_nodes}}) do
    direct_violations = Enum.flat_map(inner_nodes, &nested_transaction_violation(id, &1))
    inner_violations = do_check_nested_transactions(inner_nodes)
    direct_violations ++ inner_violations
  end

  defp check_nested_transactions_node(%FlowNode{type: :sub_process, type_data: %FlowNodeData.SubProcess{flow_nodes: inner_nodes}}) do
    do_check_nested_transactions(inner_nodes)
  end

  defp check_nested_transactions_node(_), do: []

  defp nested_transaction_violation(outer_id, %FlowNode{id: inner_id, type: :sub_process, type_data: %FlowNodeData.SubProcess{is_transaction: true}}) do
    [
      {:nested_transaction,
       "Transaction '#{outer_id}' contains nested Transaction '#{inner_id}'. " <>
         "Nested transactions are not supported in v1."}
    ]
  end

  defp nested_transaction_violation(_outer_id, _node), do: []

  # ---------------------------------------------------------------------------
  # Loop characteristics checks (MI + Standard Loop)
  # ---------------------------------------------------------------------------

  @activity_types [
    :task,
    :user_task,
    :service_task,
    :manual_task,
    :script_task,
    :business_rule_task,
    :send_task,
    :receive_task,
    :call_activity,
    :sub_process
  ]

  defp check_loop_characteristics(%BpmnProcess{} = process) do
    all_flow_nodes = collect_all_flow_nodes_flat(process.flow_nodes)
    Enum.flat_map(all_flow_nodes, &check_node_loop_characteristics/1)
  end

  defp collect_all_flow_nodes_flat(flow_nodes) do
    Enum.flat_map(flow_nodes, fn %FlowNode{type_data: type_data} = node ->
      nested =
        case type_data do
          %FlowNodeData.SubProcess{flow_nodes: inner} -> collect_all_flow_nodes_flat(inner)
          _ -> []
        end

      [node | nested]
    end)
  end

  defp check_node_loop_characteristics(%FlowNode{
         id: id,
         type: type,
         multi_instance: mi,
         standard_loop: sl
       }) do
    mutual_exclusivity_errors = check_loop_mutual_exclusivity(id, type, mi, sl)
    mi_errors = check_multi_instance_rules(id, type, mi)
    sl_errors = check_standard_loop_rules(id, type, sl)
    mutual_exclusivity_errors ++ mi_errors ++ sl_errors
  end

  defp check_loop_mutual_exclusivity(id, type, %MultiInstance{}, %StandardLoop{}) do
    [
      {:loop_mutual_exclusivity,
       "#{type_label(type)} '#{id}' has both multiInstanceLoopCharacteristics and " <>
         "standardLoopCharacteristics. Only one loop type is allowed per activity."}
    ]
  end

  defp check_loop_mutual_exclusivity(_id, _type, _mi, _sl), do: []

  defp check_multi_instance_rules(_id, _type, nil), do: []

  defp check_multi_instance_rules(id, type, %MultiInstance{} = mi) do
    position_errors = check_loop_on_valid_element(id, type, "multiInstanceLoopCharacteristics")

    collection_errors =
      if blank?(mi.collection_expression) do
        [
          {:mi_missing_collection,
           "#{type_label(type)} '#{id}' has multiInstanceLoopCharacteristics but no resolvable " <>
             "collection (evil:inputCollection or loopDataInput is required)"}
        ]
      else
        []
      end

    max_iterations_errors =
      case mi.max_iterations do
        n when is_integer(n) and n <= 0 ->
          [
            {:mi_invalid_max_iterations,
             "#{type_label(type)} '#{id}' has evil:maxIterations=#{n}; must be > 0"}
          ]

        _ ->
          []
      end

    completion_condition_errors =
      if is_binary(mi.completion_condition) and blank?(mi.completion_condition) do
        [
          {:mi_blank_completion_condition,
           "#{type_label(type)} '#{id}' has an empty completionCondition; " <>
             "remove it or provide a valid FEEL expression"}
        ]
      else
        []
      end

    break_condition_errors =
      if is_binary(mi.loop_break_condition) and blank?(mi.loop_break_condition) do
        [
          {:mi_blank_break_condition,
           "#{type_label(type)} '#{id}' has an empty evil:loopBreakCondition; " <>
             "remove it or provide a valid FEEL expression"}
        ]
      else
        []
      end

    position_errors ++
      collection_errors ++ max_iterations_errors ++ completion_condition_errors ++ break_condition_errors
  end

  defp check_standard_loop_rules(_id, _type, nil), do: []

  defp check_standard_loop_rules(id, type, %StandardLoop{} = sl) do
    position_errors = check_loop_on_valid_element(id, type, "standardLoopCharacteristics")

    condition_errors =
      if blank?(sl.loop_condition) do
        [
          {:standard_loop_missing_condition,
           "#{type_label(type)} '#{id}' has standardLoopCharacteristics but no loopCondition " <>
             "(required for execution)"}
        ]
      else
        []
      end

    max_errors =
      case sl.loop_maximum do
        n when is_integer(n) and n <= 0 ->
          [
            {:standard_loop_invalid_maximum,
             "#{type_label(type)} '#{id}' has loopMaximum=#{n}; must be > 0"}
          ]

        _ ->
          []
      end

    position_errors ++ condition_errors ++ max_errors
  end

  defp check_loop_on_valid_element(_id, type, _characteristics_name)
       when type in @activity_types,
       do: []

  defp check_loop_on_valid_element(id, type, characteristics_name) do
    [
      {:loop_on_invalid_element,
       "#{type_label(type)} '#{id}' has #{characteristics_name} but loop characteristics " <>
         "are only valid on activity elements (tasks, call activities, subprocesses)"}
    ]
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false

  defp maybe_add(list, true, item), do: list ++ [item]
  defp maybe_add(list, false, _item), do: list

  defp missing_flow_node_props_error(_id, _type, [], _scope_label), do: []

  defp missing_flow_node_props_error(id, type, missing, scope_label) do
    [
      {:incomplete_flow_node,
       scope_label <>
         "#{type_label(type)} '#{id}' is missing required properties: #{Enum.join(missing, ", ")}"}
    ]
  end

  defp missing_event_definition_props_error(_id, _type, [], _event_context, _scope_label), do: []

  defp missing_event_definition_props_error(id, type, missing, event_context, scope_label) do
    [
      {:incomplete_event_definition,
       scope_label <>
         "#{type_label(type)} '#{id}' has a #{event_context} that is missing required properties: #{Enum.join(missing, ", ")}"}
    ]
  end

  @type_labels %{
    start_event: "StartEvent",
    end_event: "EndEvent",
    intermediate_catch_event: "IntermediateCatchEvent",
    intermediate_throw_event: "IntermediateThrowEvent",
    boundary_event: "BoundaryEvent",
    task: "Task",
    user_task: "UserTask",
    service_task: "ServiceTask",
    manual_task: "ManualTask",
    script_task: "ScriptTask",
    business_rule_task: "BusinessRuleTask",
    send_task: "SendTask",
    receive_task: "ReceiveTask",
    call_activity: "CallActivity",
    sub_process: "SubProcess",
    exclusive_gateway: "ExclusiveGateway",
    parallel_gateway: "ParallelGateway",
    inclusive_gateway: "InclusiveGateway",
    event_based_gateway: "EventBasedGateway",
    complex_gateway: "ComplexGateway"
  }

  defp type_label(type), do: Map.get(@type_labels, type, "FlowNode")
end
