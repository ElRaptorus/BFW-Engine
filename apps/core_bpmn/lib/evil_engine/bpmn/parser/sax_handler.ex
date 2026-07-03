defmodule EvilEngine.BPMN.Parser.SaxHandler do
  @moduledoc """
  Saxy callback module that builds `EvilEngine.BPMN.Model.*` structs
  from SAX events. Maintains a stack-based state tracking nested elements.
  """

  @behaviour Saxy.Handler

  require Logger

  alias EvilEngine.BPMN.Model.DataAssociation
  alias EvilEngine.BPMN.Model.DataContract
  alias EvilEngine.BPMN.Model.DataObject
  alias EvilEngine.BPMN.Model.DataObjectReference
  alias EvilEngine.BPMN.Model.Definitions
  alias EvilEngine.BPMN.Model.ErrorDefinition
  alias EvilEngine.BPMN.Model.EscalationDefinition
  alias EvilEngine.BPMN.Model.EventDefinition
  alias EvilEngine.BPMN.Model.FlowNode
  alias EvilEngine.BPMN.Model.FlowNodeData
  alias EvilEngine.BPMN.Model.Lane
  alias EvilEngine.BPMN.Model.LinterRulesetScore
  alias EvilEngine.BPMN.Model.Mapping
  alias EvilEngine.BPMN.Model.MessageDefinition
  alias EvilEngine.BPMN.Model.MultiInstance
  alias EvilEngine.BPMN.Model.Process, as: BpmnProcess
  alias EvilEngine.BPMN.Model.SequenceFlow
  alias EvilEngine.BPMN.Model.SignalDefinition

  @flow_node_elements %{
    "startEvent" => {:start_event, FlowNodeData.StartEvent},
    "endEvent" => {:end_event, FlowNodeData.EndEvent},
    "intermediateCatchEvent" => {:intermediate_catch_event, FlowNodeData.IntermediateCatchEvent},
    "intermediateThrowEvent" => {:intermediate_throw_event, FlowNodeData.IntermediateThrowEvent},
    "boundaryEvent" => {:boundary_event, FlowNodeData.BoundaryEvent},
    "task" => {:task, FlowNodeData.Task},
    "userTask" => {:user_task, FlowNodeData.UserTask},
    "serviceTask" => {:service_task, FlowNodeData.ServiceTask},
    "manualTask" => {:manual_task, FlowNodeData.ManualTask},
    "scriptTask" => {:script_task, FlowNodeData.ScriptTask},
    "businessRuleTask" => {:business_rule_task, FlowNodeData.BusinessRuleTask},
    "sendTask" => {:send_task, FlowNodeData.SendTask},
    "receiveTask" => {:receive_task, FlowNodeData.ReceiveTask},
    "callActivity" => {:call_activity, FlowNodeData.CallActivity},
    "subProcess" => {:sub_process, FlowNodeData.SubProcess},
    "exclusiveGateway" => {:exclusive_gateway, FlowNodeData.ExclusiveGateway},
    "parallelGateway" => {:parallel_gateway, FlowNodeData.ParallelGateway},
    "inclusiveGateway" => {:inclusive_gateway, FlowNodeData.InclusiveGateway},
    "eventBasedGateway" => {:event_based_gateway, FlowNodeData.EventBasedGateway},
    "complexGateway" => {:complex_gateway, FlowNodeData.ComplexGateway}
  }

  @event_definition_elements %{
    "messageEventDefinition" => :message,
    "signalEventDefinition" => :signal,
    "timerEventDefinition" => :timer,
    "errorEventDefinition" => :error,
    "escalationEventDefinition" => :escalation,
    "conditionalEventDefinition" => :conditional,
    "compensateEventDefinition" => :compensation,
    "terminateEventDefinition" => :terminate,
    "cancelEventDefinition" => :cancel,
    "linkEventDefinition" => :link
  }

  @doc false
  def initial_state(raw_xml) do
    %{
      raw_xml: raw_xml,
      processes: [],
      messages: [],
      signals: [],
      errors: [],
      escalations: [],
      linter_scores: [],
      current_process: nil,
      current_node: nil,
      current_node_type: nil,
      current_node_data: nil,
      current_sequence_flow: nil,
      current_lane: nil,
      parent_lane: nil,
      current_event_def: nil,
      current_mi: nil,
      stack: [],
      subprocess_stack: [],
      text_buffer: "",
      current_extension: nil,
      current_association: nil,
      current_data_object: nil,
      default_flows: %{},
      definitions_id: nil
    }
  end

  @doc false
  def finalize(state) do
    processes =
      state.processes
      |> Enum.reverse()
      |> Enum.map(fn %BpmnProcess{} = process ->
        nil_lane_count = Enum.count(process.lanes, &is_nil/1)

        if nil_lane_count > 0 do
          Logger.warning(
            "Dropped #{nil_lane_count} nil lane(s) while finalizing process '#{process.id}'"
          )
        end

        reversed_lanes =
          process.lanes
          |> Enum.reject(&is_nil/1)
          |> Enum.reverse()
          |> Enum.map(fn %Lane{} = lane ->
            %Lane{lane | flow_node_refs: Enum.reverse(lane.flow_node_refs)}
          end)

        %BpmnProcess{
          process
          | flow_nodes: Enum.reverse(process.flow_nodes),
            sequence_flows: Enum.reverse(process.sequence_flows),
            lanes: reversed_lanes,
            data_objects: Enum.reverse(process.data_objects),
            data_object_references: Enum.reverse(process.data_object_references),
            extensions: Enum.reverse(process.extensions)
        }
      end)

    %Definitions{
      definitions_id: state.definitions_id,
      processes: processes,
      messages: Enum.reverse(state.messages),
      signals: Enum.reverse(state.signals),
      errors: Enum.reverse(state.errors),
      escalations: Enum.reverse(state.escalations),
      linter_scores: Enum.reverse(state.linter_scores),
      raw_xml: state.raw_xml
    }
  end

  # ---------------------------------------------------------------------------
  # Saxy.Handler callbacks
  # ---------------------------------------------------------------------------

  @impl Saxy.Handler
  def handle_event(:start_document, _prolog, state), do: {:ok, state}

  @impl Saxy.Handler
  def handle_event(:end_document, _data, state), do: {:ok, state}

  @impl Saxy.Handler
  def handle_event(:start_element, {raw_name, sax_attributes}, state) do
    name = local_name(raw_name)
    attributes = to_attr_map(sax_attributes)

    state = %{state | text_buffer: ""}
    handle_start(name, attributes, state)
  end

  @impl Saxy.Handler
  def handle_event(:end_element, raw_name, state) do
    name = local_name(raw_name)
    handle_end(name, state)
  end

  @impl Saxy.Handler
  def handle_event(:characters, chars, state) do
    {:ok, %{state | text_buffer: state.text_buffer <> chars}}
  end

  # ---------------------------------------------------------------------------
  # Start-element handlers
  # ---------------------------------------------------------------------------

  defp handle_start("definitions", attributes, state) do
    {:ok, %{state | definitions_id: attributes["id"]}}
  end

  defp handle_start("process", attributes, state) do
    process = %BpmnProcess{
      id: attributes["id"],
      name: attributes["name"],
      is_executable: attributes["isExecutable"] != "false"
    }

    {:ok, %{state | current_process: process, stack: [:process | state.stack]}}
  end

  defp handle_start("message", attributes, %{current_process: nil} = state) do
    message = %MessageDefinition{id: attributes["id"], name: attributes["name"]}
    {:ok, %{state | messages: [message | state.messages]}}
  end

  defp handle_start("signal", attributes, %{current_process: nil} = state) do
    signal = %SignalDefinition{id: attributes["id"], name: attributes["name"]}
    {:ok, %{state | signals: [signal | state.signals]}}
  end

  defp handle_start("error", attributes, %{current_process: nil} = state) do
    error = %ErrorDefinition{
      id: attributes["id"],
      name: attributes["name"],
      error_code: attributes["errorCode"]
    }

    {:ok, %{state | errors: [error | state.errors]}}
  end

  defp handle_start("escalation", attributes, %{current_process: nil} = state) do
    escalation = %EscalationDefinition{
      id: attributes["id"],
      name: attributes["name"],
      escalation_code: attributes["escalationCode"]
    }

    {:ok, %{state | escalations: [escalation | state.escalations]}}
  end

  defp handle_start("sequenceFlow", attributes, %{current_process: %BpmnProcess{}} = state) do
    sequence_flow = %SequenceFlow{
      id: attributes["id"],
      name: attributes["name"],
      source_ref: attributes["sourceRef"],
      target_ref: attributes["targetRef"]
    }

    {:ok, %{state | current_sequence_flow: sequence_flow, stack: [:sequence_flow | state.stack]}}
  end

  defp handle_start("conditionExpression", _attributes, state) do
    {:ok, %{state | text_buffer: "", stack: [:condition_expression | state.stack]}}
  end

  defp handle_start("lane", attributes, %{current_process: %BpmnProcess{}} = state) do
    lane = %Lane{id: attributes["id"], name: attributes["name"]}
    {:ok, %{state | current_lane: lane, stack: [:lane | state.stack]}}
  end

  defp handle_start("flowNodeRef", _attributes, state) do
    {:ok, %{state | text_buffer: "", stack: [:flow_node_ref | state.stack]}}
  end

  defp handle_start("dataObject", attributes, %{current_process: %BpmnProcess{}} = state) do
    obj = %DataObject{
      id: attributes["id"],
      name: attributes["name"],
      item_subject_ref: attributes["itemSubjectRef"]
    }

    {:ok, %{state | current_data_object: obj, stack: [:data_object | state.stack]}}
  end

  defp handle_start(
         "dataObjectReference",
         attributes,
         %{current_process: %BpmnProcess{} = process} = state
       ) do
    ref = %DataObjectReference{
      id: attributes["id"],
      name: attributes["name"],
      data_object_ref: attributes["dataObjectRef"],
      data_state: attributes["dataState"]
    }

    process = %BpmnProcess{
      process
      | data_object_references: [ref | process.data_object_references]
    }

    {:ok, %{state | current_process: process}}
  end

  defp handle_start("dataOutputAssociation", attributes, %{current_node: %FlowNode{}} = state) do
    assoc = %DataAssociation{id: attributes["id"] || "doa_#{System.unique_integer([:positive])}"}
    {:ok, %{state | current_association: assoc, stack: [:data_output_association | state.stack]}}
  end

  defp handle_start("dataInputAssociation", attributes, %{current_node: %FlowNode{}} = state) do
    assoc = %DataAssociation{id: attributes["id"] || "dia_#{System.unique_integer([:positive])}"}
    {:ok, %{state | current_association: assoc, stack: [:data_input_association | state.stack]}}
  end

  defp handle_start("sourceRef", _attributes, %{current_association: %DataAssociation{}} = state) do
    {:ok, %{state | text_buffer: "", stack: [:assoc_source_ref | state.stack]}}
  end

  defp handle_start("targetRef", _attributes, %{current_association: %DataAssociation{}} = state) do
    {:ok, %{state | text_buffer: "", stack: [:assoc_target_ref | state.stack]}}
  end

  defp handle_start(
         "transformation",
         _attributes,
         %{current_association: %DataAssociation{}} = state
       ) do
    {:ok, %{state | text_buffer: "", stack: [:assoc_transformation | state.stack]}}
  end

  defp handle_start("valueContract", _attributes, %{current_data_object: %DataObject{}} = state) do
    {:ok, %{state | text_buffer: "", stack: [:evil_value_contract | state.stack]}}
  end

  defp handle_start("laneSet", _attributes, state) do
    {:ok, %{state | stack: [:lane_set | state.stack]}}
  end

  defp handle_start("childLaneSet", _attributes, state) do
    {:ok,
     %{
       state
       | parent_lane: state.current_lane,
         stack: [:child_lane_set | state.stack]
     }}
  end

  defp handle_start("documentation", _attributes, state) do
    {:ok, %{state | text_buffer: "", stack: [:documentation | state.stack]}}
  end

  defp handle_start("multiInstanceLoopCharacteristics", attributes, state) do
    mi = %MultiInstance{
      is_sequential: attributes["isSequential"] == "true"
    }

    {:ok, %{state | current_mi: mi, stack: [:multi_instance | state.stack]}}
  end

  defp handle_start("loopCardinality", _attributes, state) do
    {:ok, %{state | text_buffer: "", stack: [:loop_cardinality | state.stack]}}
  end

  defp handle_start("completionCondition", _attributes, state) do
    {:ok, %{state | text_buffer: "", stack: [:completion_condition | state.stack]}}
  end

  defp handle_start("activationCondition", _attributes, state) do
    {:ok, %{state | text_buffer: "", stack: [:activation_condition | state.stack]}}
  end

  defp handle_start("subProcess", attributes, %{current_process: %BpmnProcess{}} = state) do
    type_data = build_initial_type_data(FlowNodeData.SubProcess, attributes)

    node = %FlowNode{
      id: attributes["id"],
      name: attributes["name"],
      type: :sub_process,
      type_data: type_data
    }

    defaults =
      case attributes["default"] do
        nil -> state.default_flows
        ref -> Map.put(state.default_flows, attributes["id"], ref)
      end

    %BpmnProcess{} = process = state.current_process

    saved_context = %{
      subprocess_node: node,
      subprocess_data: type_data,
      saved_flow_nodes: process.flow_nodes,
      saved_sequence_flows: process.sequence_flows,
      saved_data_objects: process.data_objects,
      saved_data_object_references: process.data_object_references,
      saved_default_flows: state.default_flows
    }

    cleared_process = %BpmnProcess{
      process
      | flow_nodes: [],
        sequence_flows: [],
        data_objects: [],
        data_object_references: []
    }

    {:ok,
     %{
       state
       | current_node: node,
         current_node_type: "subProcess",
         current_node_data: type_data,
         current_event_def: nil,
         default_flows: defaults,
         current_process: cleared_process,
         subprocess_stack: [saved_context | state.subprocess_stack],
         stack: [:subprocess | state.stack]
     }}
  end

  defp handle_start(name, attributes, %{current_process: %BpmnProcess{}} = state)
       when is_map_key(@flow_node_elements, name) do
    state = maybe_flush_subprocess_shell(state)

    {type_atom, data_mod} = Map.fetch!(@flow_node_elements, name)
    type_data = build_initial_type_data(data_mod, attributes)

    node = %FlowNode{
      id: attributes["id"],
      name: attributes["name"],
      type: type_atom,
      type_data: type_data
    }

    defaults =
      case attributes["default"] do
        nil -> state.default_flows
        ref -> Map.put(state.default_flows, attributes["id"], ref)
      end

    {:ok,
     %{
       state
       | current_node: node,
         current_node_type: name,
         current_node_data: type_data,
         current_event_def: nil,
         default_flows: defaults,
         stack: [:flow_node | state.stack]
     }}
  end

  defp handle_start(name, attributes, %{current_node: %FlowNode{}} = state)
       when is_map_key(@event_definition_elements, name) do
    kind = Map.fetch!(@event_definition_elements, name)
    event_def = build_event_definition(kind, attributes)

    {:ok, %{state | current_event_def: event_def, stack: [:event_definition | state.stack]}}
  end

  defp handle_start("timeDate", _attributes, state) do
    {:ok, %{state | text_buffer: "", stack: [:time_date | state.stack]}}
  end

  defp handle_start("timeDuration", _attributes, state) do
    {:ok, %{state | text_buffer: "", stack: [:time_duration | state.stack]}}
  end

  defp handle_start("timeCycle", _attributes, state) do
    {:ok, %{state | text_buffer: "", stack: [:time_cycle | state.stack]}}
  end

  defp handle_start(
         "condition",
         _attributes,
         %{current_event_def: %EventDefinition.Conditional{}} = state
       ) do
    {:ok, %{state | text_buffer: "", stack: [:conditional_expression | state.stack]}}
  end

  defp handle_start("incoming", _attributes, state) do
    {:ok, %{state | text_buffer: "", stack: [:incoming | state.stack]}}
  end

  defp handle_start("outgoing", _attributes, state) do
    {:ok, %{state | text_buffer: "", stack: [:outgoing | state.stack]}}
  end

  # evil:* extension elements
  defp handle_start("version", _attributes, %{stack: stack} = state)
       when hd(stack) == :process or hd(stack) == :extension_elements do
    {:ok, %{state | text_buffer: "", stack: [:evil_version | state.stack]}}
  end

  defp handle_start("correlationKey", _attributes, state) do
    {:ok, %{state | text_buffer: "", stack: [:evil_correlation_key | state.stack]}}
  end

  # Definitions-level linter score written by the Studio
  # (`definitions/extensionElements/evil:Properties/evil:LinterRulesetScore`).
  # `local_name/1` strips the `evil:` prefix but preserves case, so the element
  # name is `LinterRulesetScore` (upper-L). Every field is an XML attribute
  # (ESP-D17). Gated on `current_process == nil` so a same-named element inside
  # a process is ignored.
  defp handle_start("LinterRulesetScore", attributes, %{current_process: nil} = state) do
    ruleset_id = attributes["rulesetId"]

    if is_binary(ruleset_id) and ruleset_id != "" do
      score = %LinterRulesetScore{
        ruleset_id: ruleset_id,
        score_percent: parse_number_or_nil(attributes["scorePercent"]),
        compliance_status: attributes["complianceStatus"],
        computed_at_iso: attributes["computedAtIso"],
        schema_version: attributes["schemaVersion"],
        max_points: parse_number_or_nil(attributes["maxPoints"]),
        penalty_points: parse_number_or_nil(attributes["penaltyPoints"]),
        raw_error_findings: parse_integer_or_nil(attributes["rawErrorFindings"]),
        raw_warning_findings: parse_integer_or_nil(attributes["rawWarningFindings"])
      }

      {:ok, %{state | linter_scores: [score | state.linter_scores]}}
    else
      {:ok, state}
    end
  end

  defp handle_start("assignees", _attributes, state) do
    {:ok, %{state | text_buffer: "", stack: [:evil_assignees | state.stack]}}
  end

  defp handle_start("formFields", _attributes, state) do
    {:ok, %{state | text_buffer: "", stack: [:evil_form_fields | state.stack]}}
  end

  defp handle_start("formActions", _attributes, state) do
    {:ok, %{state | text_buffer: "", stack: [:evil_form_actions | state.stack]}}
  end

  defp handle_start("resultContract", _attributes, state) do
    {:ok, %{state | text_buffer: "", stack: [:evil_result_contract | state.stack]}}
  end

  defp handle_start("payloadContract", _attributes, state) do
    {:ok, %{state | text_buffer: "", stack: [:evil_payload_contract | state.stack]}}
  end

  defp handle_start("implementation", _attributes, state) do
    {:ok, %{state | text_buffer: "", stack: [:evil_implementation | state.stack]}}
  end

  defp handle_start("scriptRef", _attributes, state) do
    {:ok, %{state | text_buffer: "", stack: [:evil_script_ref | state.stack]}}
  end

  defp handle_start("httpUrl", _attributes, state) do
    {:ok, %{state | text_buffer: "", stack: [:evil_http_url | state.stack]}}
  end

  defp handle_start("httpMethod", _attributes, state) do
    {:ok, %{state | text_buffer: "", stack: [:evil_http_method | state.stack]}}
  end

  defp handle_start("httpBody", _attributes, state) do
    {:ok, %{state | text_buffer: "", stack: [:evil_http_body | state.stack]}}
  end

  defp handle_start("httpAuthHeader", _attributes, state) do
    {:ok, %{state | text_buffer: "", stack: [:evil_http_auth_header | state.stack]}}
  end

  defp handle_start("httpResponseHeaders", _attributes, state) do
    {:ok, %{state | text_buffer: "", stack: [:evil_http_response_headers | state.stack]}}
  end

  defp handle_start("dueDate", _attributes, state) do
    {:ok, %{state | text_buffer: "", stack: [:evil_due_date | state.stack]}}
  end

  defp handle_start("priority", _attributes, state) do
    {:ok, %{state | text_buffer: "", stack: [:evil_priority | state.stack]}}
  end

  defp handle_start("requireConfirmation", _attributes, state) do
    {:ok, %{state | text_buffer: "", stack: [:evil_require_confirmation | state.stack]}}
  end

  defp handle_start("correlationRetrievalExpression", _attributes, state) do
    {:ok, %{state | text_buffer: "", stack: [:evil_correlation_retrieval | state.stack]}}
  end

  defp handle_start("payload", _attributes, state) do
    {:ok, %{state | text_buffer: "", stack: [:evil_payload | state.stack]}}
  end

  defp handle_start("eventMapping", _attributes, state) do
    {:ok, %{state | text_buffer: "", stack: [:evil_event_mapping | state.stack]}}
  end

  defp handle_start("errorCode", _attributes, state) do
    {:ok, %{state | text_buffer: "", stack: [:evil_error_code | state.stack]}}
  end

  defp handle_start("errorMessage", _attributes, state) do
    {:ok, %{state | text_buffer: "", stack: [:evil_error_message | state.stack]}}
  end

  defp handle_start("inputCollection", _attributes, state) do
    {:ok, %{state | text_buffer: "", stack: [:evil_input_collection | state.stack]}}
  end

  defp handle_start("outputCollection", _attributes, state) do
    {:ok, %{state | text_buffer: "", stack: [:evil_output_collection | state.stack]}}
  end

  defp handle_start("loopBreakCondition", _attributes, state) do
    {:ok, %{state | text_buffer: "", stack: [:evil_loop_break_condition | state.stack]}}
  end

  defp handle_start("loopInterval", _attributes, state) do
    {:ok, %{state | text_buffer: "", stack: [:evil_loop_interval | state.stack]}}
  end

  defp handle_start("maxIterations", _attributes, state) do
    {:ok, %{state | text_buffer: "", stack: [:evil_max_iterations | state.stack]}}
  end

  defp handle_start("startEventId", _attributes, state) do
    {:ok, %{state | text_buffer: "", stack: [:evil_start_event_id | state.stack]}}
  end

  defp handle_start("decisionRef", _attributes, state) do
    {:ok, %{state | text_buffer: "", stack: [:evil_decision_ref | state.stack]}}
  end

  defp handle_start("decisionElementId", _attributes, state) do
    {:ok, %{state | text_buffer: "", stack: [:evil_decision_element_id | state.stack]}}
  end

  defp handle_start("resultVariable", _attributes, state) do
    {:ok, %{state | text_buffer: "", stack: [:evil_result_variable | state.stack]}}
  end

  defp handle_start("ruleRef", _attributes, state) do
    {:ok, %{state | text_buffer: "", stack: [:evil_rule_ref | state.stack]}}
  end

  defp handle_start("traceUnmatchedRules", _attributes, state) do
    {:ok, %{state | text_buffer: "", stack: [:evil_trace_unmatched_rules | state.stack]}}
  end

  defp handle_start("extensionElements", _attributes, state) do
    {:ok, %{state | stack: [:extension_elements | state.stack]}}
  end

  defp handle_start("dataContract", _attributes, state) do
    {:ok, %{state | text_buffer: "", stack: [:evil_data_contract | state.stack]}}
  end

  defp handle_start("script", _attributes, state) do
    {:ok, %{state | text_buffer: "", stack: [:script | state.stack]}}
  end

  defp handle_start("inputMapping", attributes, state) do
    mapping = %Mapping{source: attributes["source"] || "", target: attributes["target"] || ""}
    {:ok, %{state | current_extension: {:input_mapping, mapping}}}
  end

  defp handle_start("outputMapping", attributes, state) do
    mapping = %Mapping{source: attributes["source"] || "", target: attributes["target"] || ""}
    {:ok, %{state | current_extension: {:output_mapping, mapping}}}
  end

  defp handle_start(_name, _attributes, state), do: {:ok, state}

  # ---------------------------------------------------------------------------
  # End-element handlers
  # ---------------------------------------------------------------------------

  defp handle_end("process", state) do
    process =
      state.current_process
      |> apply_default_flows(state.default_flows)
      |> link_boundary_refs()

    {:ok,
     %{
       state
       | processes: [process | state.processes],
         current_process: nil,
         default_flows: %{},
         stack: tl(state.stack)
     }}
  end

  defp handle_end("sequenceFlow", state) do
    sequence_flow = state.current_sequence_flow
    %BpmnProcess{} = process = state.current_process
    process = %BpmnProcess{process | sequence_flows: [sequence_flow | process.sequence_flows]}

    {:ok, %{state | current_sequence_flow: nil, current_process: process, stack: tl(state.stack)}}
  end

  defp handle_end("conditionExpression", state) do
    text = String.trim(state.text_buffer)
    %SequenceFlow{} = sequence_flow = state.current_sequence_flow

    sequence_flow =
      if text != "" do
        %SequenceFlow{sequence_flow | condition_expression: text}
      else
        sequence_flow
      end

    {:ok,
     %{state | current_sequence_flow: sequence_flow, text_buffer: "", stack: tl(state.stack)}}
  end

  defp handle_end("lane", state) do
    lane = state.current_lane
    %BpmnProcess{} = process = state.current_process
    process = %BpmnProcess{process | lanes: [lane | process.lanes]}

    {:ok, %{state | current_lane: nil, current_process: process, stack: tl(state.stack)}}
  end

  defp handle_end("flowNodeRef", state) do
    ref = String.trim(state.text_buffer)
    %Lane{} = current_lane = state.current_lane
    lane = %Lane{current_lane | flow_node_refs: [ref | current_lane.flow_node_refs]}

    {:ok, %{state | current_lane: lane, text_buffer: "", stack: tl(state.stack)}}
  end

  defp handle_end("laneSet", state) do
    {:ok, %{state | stack: tl(state.stack)}}
  end

  defp handle_end("childLaneSet", state) do
    {:ok,
     %{
       state
       | current_lane: state.parent_lane,
         parent_lane: nil,
         stack: tl(state.stack)
     }}
  end

  defp handle_end("documentation", %{current_node: %FlowNode{} = node} = state) do
    text = String.trim(state.text_buffer)
    node = if text != "", do: %FlowNode{node | documentation: text}, else: node

    {:ok, %{state | current_node: node, text_buffer: "", stack: tl(state.stack)}}
  end

  defp handle_end("documentation", state) do
    {:ok, %{state | text_buffer: "", stack: tl(state.stack)}}
  end

  defp handle_end("multiInstanceLoopCharacteristics", state) do
    %FlowNode{} = current = state.current_node
    node = %FlowNode{current | multi_instance: state.current_mi}

    {:ok, %{state | current_node: node, current_mi: nil, stack: tl(state.stack)}}
  end

  defp handle_end("loopCardinality", state) do
    text = String.trim(state.text_buffer)
    mi = update_mi(state.current_mi, :cardinality_expression, text)

    {:ok, %{state | current_mi: mi, text_buffer: "", stack: tl(state.stack)}}
  end

  defp handle_end("completionCondition", state) do
    text = String.trim(state.text_buffer)
    mi = update_mi(state.current_mi, :completion_condition, text)

    {:ok, %{state | current_mi: mi, text_buffer: "", stack: tl(state.stack)}}
  end

  defp handle_end("activationCondition", %{stack: [:activation_condition | rest]} = state) do
    text = String.trim(state.text_buffer)

    data =
      case state.current_node_data do
        %FlowNodeData.ComplexGateway{} = gateway ->
          %FlowNodeData.ComplexGateway{gateway | activation_condition: text}

        other ->
          other
      end

    {:ok, %{state | current_node_data: data, text_buffer: "", stack: rest}}
  end

  defp handle_end("subProcess", state) do
    state = maybe_flush_subprocess_shell(state)
    [saved | rest_subprocess_stack] = state.subprocess_stack

    %BpmnProcess{} = process = state.current_process
    child_flow_nodes = Enum.reverse(process.flow_nodes)
    child_sequence_flows = Enum.reverse(process.sequence_flows)
    child_data_objects = Enum.reverse(process.data_objects)
    child_data_object_references = Enum.reverse(process.data_object_references)

    inner_scope = %BpmnProcess{
      process
      | flow_nodes: child_flow_nodes,
        sequence_flows: child_sequence_flows
    }

    inner_scope = apply_default_flows(inner_scope, state.default_flows)
    inner_scope = link_boundary_refs(inner_scope)

    subprocess_data = %{
      saved.subprocess_data
      | flow_nodes: inner_scope.flow_nodes,
        sequence_flows: inner_scope.sequence_flows,
        data_objects: child_data_objects,
        data_object_references: child_data_object_references
    }

    node = %{saved.subprocess_node | type_data: subprocess_data}

    restored_process = %BpmnProcess{
      process
      | flow_nodes: [node | saved.saved_flow_nodes],
        sequence_flows: saved.saved_sequence_flows,
        data_objects: saved.saved_data_objects,
        data_object_references: saved.saved_data_object_references
    }

    {:ok,
     %{
       state
       | current_node: nil,
         current_node_type: nil,
         current_node_data: nil,
         current_event_def: nil,
         default_flows: saved.saved_default_flows,
         current_process: restored_process,
         subprocess_stack: rest_subprocess_stack,
         stack: tl(state.stack)
     }}
  end

  defp handle_end(name, state) when is_map_key(@flow_node_elements, name) do
    %FlowNode{} = node = state.current_node
    data = state.current_node_data

    data = maybe_apply_event_def(data, state.current_event_def)
    node = %FlowNode{node | type_data: data}

    %BpmnProcess{} = process = state.current_process
    process = %BpmnProcess{process | flow_nodes: [node | process.flow_nodes]}

    {:ok,
     %{
       state
       | current_node: nil,
         current_node_type: nil,
         current_node_data: nil,
         current_event_def: nil,
         current_process: process,
         stack: tl(state.stack)
     }}
  end

  defp handle_end(name, state) when is_map_key(@event_definition_elements, name) do
    {:ok, %{state | stack: tl(state.stack)}}
  end

  defp handle_end("timeDate", state) do
    text = String.trim(state.text_buffer)
    event_def = set_timer_field(state.current_event_def, :time_date, text)

    {:ok, %{state | current_event_def: event_def, text_buffer: "", stack: tl(state.stack)}}
  end

  defp handle_end("timeDuration", state) do
    text = String.trim(state.text_buffer)
    event_def = set_timer_field(state.current_event_def, :time_duration, text)

    {:ok, %{state | current_event_def: event_def, text_buffer: "", stack: tl(state.stack)}}
  end

  defp handle_end("timeCycle", state) do
    text = String.trim(state.text_buffer)
    event_def = set_timer_field(state.current_event_def, :time_cycle, text)

    {:ok, %{state | current_event_def: event_def, text_buffer: "", stack: tl(state.stack)}}
  end

  defp handle_end("condition", state) do
    text = String.trim(state.text_buffer)

    event_def =
      case state.current_event_def do
        %EventDefinition.Conditional{} = ed ->
          %EventDefinition.Conditional{ed | condition_expression: text}

        other ->
          other
      end

    {:ok, %{state | current_event_def: event_def, text_buffer: "", stack: tl(state.stack)}}
  end

  defp handle_end("dataObject", %{stack: [:data_object | rest]} = state) do
    %DataObject{} = obj = state.current_data_object
    %BpmnProcess{} = process = state.current_process
    process = %BpmnProcess{process | data_objects: [obj | process.data_objects]}

    {:ok, %{state | current_data_object: nil, current_process: process, stack: rest}}
  end

  defp handle_end("dataOutputAssociation", %{stack: [:data_output_association | rest]} = state) do
    %DataAssociation{} = assoc = state.current_association
    %FlowNode{} = node = state.current_node
    node = %FlowNode{node | data_output_associations: [assoc | node.data_output_associations]}

    {:ok, %{state | current_node: node, current_association: nil, stack: rest}}
  end

  defp handle_end("dataInputAssociation", %{stack: [:data_input_association | rest]} = state) do
    %DataAssociation{} = assoc = state.current_association
    %FlowNode{} = node = state.current_node
    node = %FlowNode{node | data_input_associations: [assoc | node.data_input_associations]}

    {:ok, %{state | current_node: node, current_association: nil, stack: rest}}
  end

  defp handle_end(
         "sourceRef",
         %{stack: [:assoc_source_ref | rest], current_association: %DataAssociation{} = assoc} =
           state
       ) do
    text = String.trim(state.text_buffer)
    assoc = %DataAssociation{assoc | source_ref: text}
    {:ok, %{state | current_association: assoc, text_buffer: "", stack: rest}}
  end

  defp handle_end(
         "targetRef",
         %{stack: [:assoc_target_ref | rest], current_association: %DataAssociation{} = assoc} =
           state
       ) do
    text = String.trim(state.text_buffer)
    assoc = %DataAssociation{assoc | target_ref: text}
    {:ok, %{state | current_association: assoc, text_buffer: "", stack: rest}}
  end

  defp handle_end(
         "transformation",
         %{stack: [:assoc_transformation | rest], current_association: %DataAssociation{} = assoc} =
           state
       ) do
    text = String.trim(state.text_buffer)
    assoc = if text != "", do: %DataAssociation{assoc | value_expression: text}, else: assoc
    {:ok, %{state | current_association: assoc, text_buffer: "", stack: rest}}
  end

  defp handle_end(
         "valueContract",
         %{stack: [:evil_value_contract | rest], current_data_object: %DataObject{} = obj} = state
       ) do
    text = String.trim(state.text_buffer)
    schema = parse_json_text(text)

    obj =
      case {schema, text} do
        {nil, ""} ->
          obj

        {nil, _unparseable} ->
          Logger.warning(
            "DataObject '#{obj.id}': evil:valueContract contains unparseable JSON, ignoring"
          )

          obj

        {parsed, _} ->
          %DataObject{obj | value_contract: parsed}
      end

    {:ok, %{state | current_data_object: obj, text_buffer: "", stack: rest}}
  end

  defp handle_end("incoming", %{current_node: %FlowNode{} = node} = state) do
    ref = String.trim(state.text_buffer)
    node = %FlowNode{node | incoming: [ref | node.incoming]}

    {:ok, %{state | current_node: node, text_buffer: "", stack: tl(state.stack)}}
  end

  defp handle_end("incoming", %{current_node: nil, subprocess_stack: [saved | rest]} = state) do
    ref = String.trim(state.text_buffer)
    %FlowNode{} = subprocess_node = saved.subprocess_node
    node = %FlowNode{subprocess_node | incoming: [ref | subprocess_node.incoming]}

    {:ok,
     %{
       state
       | subprocess_stack: [%{saved | subprocess_node: node} | rest],
         text_buffer: "",
         stack: tl(state.stack)
     }}
  end

  defp handle_end("outgoing", %{current_node: %FlowNode{} = node} = state) do
    ref = String.trim(state.text_buffer)
    node = %FlowNode{node | outgoing: [ref | node.outgoing]}

    {:ok, %{state | current_node: node, text_buffer: "", stack: tl(state.stack)}}
  end

  defp handle_end("outgoing", %{current_node: nil, subprocess_stack: [saved | rest]} = state) do
    ref = String.trim(state.text_buffer)
    %FlowNode{} = subprocess_node = saved.subprocess_node
    node = %FlowNode{subprocess_node | outgoing: [ref | subprocess_node.outgoing]}

    {:ok,
     %{
       state
       | subprocess_stack: [%{saved | subprocess_node: node} | rest],
         text_buffer: "",
         stack: tl(state.stack)
     }}
  end

  defp handle_end("version", %{stack: [:evil_version | rest]} = state) do
    text = String.trim(state.text_buffer)

    state =
      case state.current_process do
        %BpmnProcess{} = process when text != "" ->
          %{state | current_process: %BpmnProcess{process | version: text}}

        _ ->
          state
      end

    {:ok, %{state | text_buffer: "", stack: rest}}
  end

  defp handle_end("correlationKey", %{stack: [:evil_correlation_key | rest]} = state) do
    text = String.trim(state.text_buffer)

    state =
      case state.current_process do
        %BpmnProcess{} = process when text != "" ->
          %{state | current_process: %BpmnProcess{process | correlation_key: text}}

        _ ->
          state
      end

    {:ok, %{state | text_buffer: "", stack: rest}}
  end

  defp handle_end("assignees", %{stack: [:evil_assignees | rest]} = state) do
    text = String.trim(state.text_buffer)

    data =
      case state.current_node_data do
        %FlowNodeData.UserTask{} = d -> %FlowNodeData.UserTask{d | assignees_expression: text}
        other -> other
      end

    {:ok, %{state | current_node_data: data, text_buffer: "", stack: rest}}
  end

  defp handle_end("formFields", %{stack: [:evil_form_fields | rest]} = state) do
    text = String.trim(state.text_buffer)
    schema = parse_json_text(text)

    data =
      case state.current_node_data do
        %FlowNodeData.UserTask{} = d -> %FlowNodeData.UserTask{d | form_schema: schema}
        other -> other
      end

    {:ok, %{state | current_node_data: data, text_buffer: "", stack: rest}}
  end

  defp handle_end("formActions", %{stack: [:evil_form_actions | rest]} = state) do
    text = String.trim(state.text_buffer)
    parsed = parse_json_text(text)

    actions =
      case parsed do
        list when is_list(list) -> list
        _ -> nil
      end

    data =
      case state.current_node_data do
        %FlowNodeData.UserTask{} = d -> %FlowNodeData.UserTask{d | form_actions: actions}
        other -> other
      end

    {:ok, %{state | current_node_data: data, text_buffer: "", stack: rest}}
  end

  defp handle_end("resultContract", %{
         stack: [:evil_result_contract | rest],
         current_node_data: nil,
         subprocess_stack: [saved | rest_subprocess]
       } = state) do
    text = String.trim(state.text_buffer)
    schema = parse_json_text(text)
    data = apply_result_contract(saved.subprocess_data, schema)

    {:ok,
     %{
       state
       | subprocess_stack: [%{saved | subprocess_data: data} | rest_subprocess],
         text_buffer: "",
         stack: rest
     }}
  end

  defp handle_end("resultContract", %{stack: [:evil_result_contract | rest]} = state) do
    text = String.trim(state.text_buffer)
    schema = parse_json_text(text)
    data = apply_result_contract(state.current_node_data, schema)
    {:ok, %{state | current_node_data: data, text_buffer: "", stack: rest}}
  end

  defp handle_end("payloadContract", %{
         stack: [:evil_payload_contract | rest],
         current_node_data: nil,
         subprocess_stack: [saved | rest_subprocess]
       } = state) do
    text = String.trim(state.text_buffer)
    schema = parse_json_text(text)
    data = apply_payload_contract(saved.subprocess_data, schema)

    {:ok,
     %{
       state
       | subprocess_stack: [%{saved | subprocess_data: data} | rest_subprocess],
         text_buffer: "",
         stack: rest
     }}
  end

  defp handle_end("payloadContract", %{stack: [:evil_payload_contract | rest]} = state) do
    text = String.trim(state.text_buffer)
    schema = parse_json_text(text)
    data = apply_payload_contract(state.current_node_data, schema)
    {:ok, %{state | current_node_data: data, text_buffer: "", stack: rest}}
  end

  defp handle_end("implementation", %{stack: [:evil_implementation | rest]} = state) do
    text = String.trim(state.text_buffer)

    data =
      case state.current_node_data do
        %FlowNodeData.BusinessRuleTask{} = d ->
          %FlowNodeData.BusinessRuleTask{d | implementation: text}

        other ->
          other
      end

    {:ok, %{state | current_node_data: data, text_buffer: "", stack: rest}}
  end

  defp handle_end("scriptRef", %{stack: [:evil_script_ref | rest]} = state) do
    text = String.trim(state.text_buffer)

    data =
      case state.current_node_data do
        %FlowNodeData.ScriptTask{} = d ->
          %FlowNodeData.ScriptTask{d | script_ref: text}

        other ->
          other
      end

    {:ok, %{state | current_node_data: data, text_buffer: "", stack: rest}}
  end

  defp handle_end("httpUrl", %{stack: [:evil_http_url | rest]} = state) do
    text = String.trim(state.text_buffer)

    data =
      case state.current_node_data do
        %FlowNodeData.ServiceTask{} = d -> %{d | http_url: text}
        other -> other
      end

    {:ok, %{state | current_node_data: data, text_buffer: "", stack: rest}}
  end

  defp handle_end("httpMethod", %{stack: [:evil_http_method | rest]} = state) do
    text = String.trim(state.text_buffer)

    data =
      case state.current_node_data do
        %FlowNodeData.ServiceTask{} = d -> %{d | http_method: String.upcase(text)}
        other -> other
      end

    {:ok, %{state | current_node_data: data, text_buffer: "", stack: rest}}
  end

  defp handle_end("httpBody", %{stack: [:evil_http_body | rest]} = state) do
    text = String.trim(state.text_buffer)

    data =
      case state.current_node_data do
        %FlowNodeData.ServiceTask{} = d -> %{d | http_body: text}
        other -> other
      end

    {:ok, %{state | current_node_data: data, text_buffer: "", stack: rest}}
  end

  defp handle_end("httpAuthHeader", %{stack: [:evil_http_auth_header | rest]} = state) do
    text = String.trim(state.text_buffer)

    data =
      case state.current_node_data do
        %FlowNodeData.ServiceTask{} = d -> %{d | http_auth_header: text}
        other -> other
      end

    {:ok, %{state | current_node_data: data, text_buffer: "", stack: rest}}
  end

  defp handle_end("httpResponseHeaders", %{stack: [:evil_http_response_headers | rest]} = state) do
    text = String.trim(state.text_buffer)

    data =
      case state.current_node_data do
        %FlowNodeData.ServiceTask{} = d -> %{d | http_response_headers: text}
        other -> other
      end

    {:ok, %{state | current_node_data: data, text_buffer: "", stack: rest}}
  end

  defp handle_end("dueDate", %{stack: [:evil_due_date | rest]} = state) do
    text = String.trim(state.text_buffer)

    data =
      case state.current_node_data do
        %FlowNodeData.UserTask{} = d -> %FlowNodeData.UserTask{d | due_date: text}
        other -> other
      end

    {:ok, %{state | current_node_data: data, text_buffer: "", stack: rest}}
  end

  defp handle_end("priority", %{stack: [:evil_priority | rest]} = state) do
    text = String.trim(state.text_buffer)

    data =
      case state.current_node_data do
        %FlowNodeData.UserTask{} = d -> %FlowNodeData.UserTask{d | priority: parse_int_attr(text)}
        other -> other
      end

    {:ok, %{state | current_node_data: data, text_buffer: "", stack: rest}}
  end

  defp handle_end("requireConfirmation", %{stack: [:evil_require_confirmation | rest]} = state) do
    text = String.trim(state.text_buffer)

    data =
      case state.current_node_data do
        %FlowNodeData.ManualTask{} = d ->
          %FlowNodeData.ManualTask{d | require_confirmation: text == "true"}

        other ->
          other
      end

    {:ok, %{state | current_node_data: data, text_buffer: "", stack: rest}}
  end

  defp handle_end(
         "correlationRetrievalExpression",
         %{stack: [:evil_correlation_retrieval | rest]} = state
       ) do
    text = String.trim(state.text_buffer)

    event_def =
      case state.current_event_def do
        %EventDefinition.Message{} = ed ->
          %EventDefinition.Message{ed | correlation_retrieval_expression: text}

        other ->
          other
      end

    {:ok, %{state | current_event_def: event_def, text_buffer: "", stack: rest}}
  end

  defp handle_end("payload", %{stack: [:evil_payload | rest]} = state) do
    text = String.trim(state.text_buffer)

    event_def =
      case state.current_event_def do
        %EventDefinition.Message{} = ed ->
          %EventDefinition.Message{ed | payload_expression: text}

        other ->
          other
      end

    {:ok, %{state | current_event_def: event_def, text_buffer: "", stack: rest}}
  end

  defp handle_end("eventMapping", %{stack: [:evil_event_mapping | rest]} = state) do
    text = String.trim(state.text_buffer)

    event_def =
      case state.current_event_def do
        %EventDefinition.Message{} = ed ->
          %EventDefinition.Message{ed | event_mapping: text}

        other ->
          other
      end

    {:ok, %{state | current_event_def: event_def, text_buffer: "", stack: rest}}
  end

  defp handle_end("errorCode", %{stack: [:evil_error_code | rest]} = state) do
    text = String.trim(state.text_buffer)

    event_def =
      case state.current_event_def do
        %EventDefinition.Error{} = ed ->
          %EventDefinition.Error{ed | error_code: text}

        other ->
          other
      end

    {:ok, %{state | current_event_def: event_def, text_buffer: "", stack: rest}}
  end

  defp handle_end("errorMessage", %{stack: [:evil_error_message | rest]} = state) do
    text = String.trim(state.text_buffer)

    event_def =
      case state.current_event_def do
        %EventDefinition.Error{} = ed ->
          %EventDefinition.Error{ed | error_message: text}

        other ->
          other
      end

    {:ok, %{state | current_event_def: event_def, text_buffer: "", stack: rest}}
  end

  defp handle_end("inputCollection", %{stack: [:evil_input_collection | rest]} = state) do
    text = String.trim(state.text_buffer)
    mi = update_mi(state.current_mi, :collection_expression, text)

    {:ok, %{state | current_mi: mi, text_buffer: "", stack: rest}}
  end

  defp handle_end("outputCollection", %{stack: [:evil_output_collection | rest]} = state) do
    text = String.trim(state.text_buffer)
    mi = update_mi(state.current_mi, :output_collection, text)

    {:ok, %{state | current_mi: mi, text_buffer: "", stack: rest}}
  end

  defp handle_end("loopBreakCondition", %{stack: [:evil_loop_break_condition | rest]} = state) do
    text = String.trim(state.text_buffer)
    mi = update_mi(state.current_mi, :loop_break_condition, text)

    {:ok, %{state | current_mi: mi, text_buffer: "", stack: rest}}
  end

  defp handle_end("loopInterval", %{stack: [:evil_loop_interval | rest]} = state) do
    text = String.trim(state.text_buffer)
    mi = update_mi(state.current_mi, :loop_interval, text)

    {:ok, %{state | current_mi: mi, text_buffer: "", stack: rest}}
  end

  defp handle_end("maxIterations", %{stack: [:evil_max_iterations | rest]} = state) do
    text = String.trim(state.text_buffer)

    mi =
      case state.current_mi do
        %MultiInstance{} = m when text != "" ->
          %MultiInstance{m | max_iterations: parse_int_attr(text)}

        other ->
          other
      end

    {:ok, %{state | current_mi: mi, text_buffer: "", stack: rest}}
  end

  defp handle_end("startEventId", %{stack: [:evil_start_event_id | rest]} = state) do
    text = String.trim(state.text_buffer)

    data =
      case state.current_node_data do
        %FlowNodeData.CallActivity{} = d when text != "" ->
          %FlowNodeData.CallActivity{d | start_event_id: text}

        other ->
          other
      end

    {:ok, %{state | current_node_data: data, text_buffer: "", stack: rest}}
  end

  defp handle_end("decisionRef", %{stack: [:evil_decision_ref | rest]} = state) do
    text = String.trim(state.text_buffer)

    data =
      case state.current_node_data do
        %FlowNodeData.BusinessRuleTask{} = d ->
          %FlowNodeData.BusinessRuleTask{d | decision_ref: text}

        other ->
          other
      end

    {:ok, %{state | current_node_data: data, text_buffer: "", stack: rest}}
  end

  defp handle_end("decisionElementId", %{stack: [:evil_decision_element_id | rest]} = state) do
    text = String.trim(state.text_buffer)

    data =
      case state.current_node_data do
        %FlowNodeData.BusinessRuleTask{} = d ->
          %FlowNodeData.BusinessRuleTask{d | decision_element_id: text}

        other ->
          other
      end

    {:ok, %{state | current_node_data: data, text_buffer: "", stack: rest}}
  end

  defp handle_end("resultVariable", %{stack: [:evil_result_variable | rest]} = state) do
    text = String.trim(state.text_buffer)

    data =
      case state.current_node_data do
        %FlowNodeData.BusinessRuleTask{} = d ->
          %FlowNodeData.BusinessRuleTask{d | result_variable: text}

        other ->
          other
      end

    {:ok, %{state | current_node_data: data, text_buffer: "", stack: rest}}
  end

  defp handle_end("ruleRef", %{stack: [:evil_rule_ref | rest]} = state) do
    text = String.trim(state.text_buffer)

    data =
      case state.current_node_data do
        %FlowNodeData.BusinessRuleTask{} = d ->
          %FlowNodeData.BusinessRuleTask{d | rule_ref: text}

        other ->
          other
      end

    {:ok, %{state | current_node_data: data, text_buffer: "", stack: rest}}
  end

  defp handle_end("traceUnmatchedRules", %{stack: [:evil_trace_unmatched_rules | rest]} = state) do
    text = String.trim(state.text_buffer)

    data =
      case state.current_node_data do
        %FlowNodeData.BusinessRuleTask{} = d ->
          %FlowNodeData.BusinessRuleTask{d | trace_unmatched_rules: text == "true"}

        other ->
          other
      end

    {:ok, %{state | current_node_data: data, text_buffer: "", stack: rest}}
  end

  defp handle_end("extensionElements", state) do
    {:ok, %{state | stack: tl(state.stack)}}
  end

  defp handle_end("dataContract", %{stack: [:evil_data_contract | rest]} = state) do
    text = String.trim(state.text_buffer)
    parsed = parse_json_text(text)

    state =
      case {parsed, state.current_node} do
        {parsed, %FlowNode{} = node} when parsed != nil ->
          direction = if parsed["direction"] == "output", do: :output, else: :input
          schema_map = parsed["schema"] || parsed

          contract = %DataContract{
            direction: direction,
            json_schema: schema_map
          }

          node = %FlowNode{node | data_contracts: [contract | node.data_contracts]}
          %{state | current_node: node}

        _ ->
          state
      end

    {:ok, %{state | text_buffer: "", stack: rest}}
  end

  defp handle_end("script", %{stack: [:script | rest]} = state) do
    text = String.trim(state.text_buffer)

    data =
      case state.current_node_data do
        %FlowNodeData.ScriptTask{} = d -> %FlowNodeData.ScriptTask{d | script: text}
        %FlowNodeData.BusinessRuleTask{} = d -> %FlowNodeData.BusinessRuleTask{d | script: text}
        other -> other
      end

    {:ok, %{state | current_node_data: data, text_buffer: "", stack: rest}}
  end

  defp handle_end("inputMapping", %{current_node_data: nil, subprocess_stack: [saved | rest]} = state) do
    case state.current_extension do
      {:input_mapping, mapping} ->
        data = append_mapping(saved.subprocess_data, :in_mappings, mapping)

        {:ok,
         %{
           state
           | subprocess_stack: [%{saved | subprocess_data: data} | rest],
             current_extension: nil
         }}

      _ ->
        {:ok, state}
    end
  end

  defp handle_end("inputMapping", state) do
    case state.current_extension do
      {:input_mapping, mapping} ->
        data = append_mapping(state.current_node_data, :in_mappings, mapping)
        {:ok, %{state | current_node_data: data, current_extension: nil}}

      _ ->
        {:ok, state}
    end
  end

  defp handle_end("outputMapping", %{current_node_data: nil, subprocess_stack: [saved | rest]} = state) do
    case state.current_extension do
      {:output_mapping, mapping} ->
        data = append_mapping(saved.subprocess_data, :out_mappings, mapping)

        {:ok,
         %{
           state
           | subprocess_stack: [%{saved | subprocess_data: data} | rest],
             current_extension: nil
         }}

      _ ->
        {:ok, state}
    end
  end

  defp handle_end("outputMapping", state) do
    case state.current_extension do
      {:output_mapping, mapping} ->
        data = append_mapping(state.current_node_data, :out_mappings, mapping)
        {:ok, %{state | current_node_data: data, current_extension: nil}}

      _ ->
        {:ok, state}
    end
  end

  defp handle_end("incoming", state) do
    {:ok, %{state | text_buffer: "", stack: tl(state.stack)}}
  end

  defp handle_end("outgoing", state) do
    {:ok, %{state | text_buffer: "", stack: tl(state.stack)}}
  end

  defp handle_end(_name, state), do: {:ok, state}

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp local_name(name) do
    case String.split(name, ":", parts: 2) do
      [_ns, local] -> local
      [local] -> local
    end
  end

  defp to_attr_map(sax_attributes) do
    Map.new(sax_attributes, fn {key, value} ->
      {local_name(key), value}
    end)
  end

  defp build_initial_type_data(FlowNodeData.BoundaryEvent, attributes) do
    %FlowNodeData.BoundaryEvent{
      attached_to_ref: attributes["attachedToRef"],
      cancel_activity: attributes["cancelActivity"] != "false"
    }
  end

  defp build_initial_type_data(FlowNodeData.CallActivity, attributes) do
    %FlowNodeData.CallActivity{called_element: attributes["calledElement"]}
  end

  defp build_initial_type_data(FlowNodeData.SubProcess, attributes) do
    %FlowNodeData.SubProcess{triggered_by_event: attributes["triggeredByEvent"] == "true"}
  end

  defp build_initial_type_data(FlowNodeData.ExclusiveGateway, _attributes) do
    %FlowNodeData.ExclusiveGateway{}
  end

  defp build_initial_type_data(FlowNodeData.InclusiveGateway, _attributes) do
    %FlowNodeData.InclusiveGateway{}
  end

  defp build_initial_type_data(FlowNodeData.ScriptTask, attributes) do
    %FlowNodeData.ScriptTask{
      script_format: attributes["scriptFormat"]
    }
  end

  defp build_initial_type_data(FlowNodeData.SendTask, attributes) do
    %FlowNodeData.SendTask{message_ref: attributes["messageRef"]}
  end

  defp build_initial_type_data(FlowNodeData.ReceiveTask, attributes) do
    %FlowNodeData.ReceiveTask{message_ref: attributes["messageRef"]}
  end

  defp build_initial_type_data(FlowNodeData.ServiceTask, attributes) do
    %FlowNodeData.ServiceTask{implementation: attributes["implementation"]}
  end

  defp build_initial_type_data(FlowNodeData.BusinessRuleTask, attributes) do
    %FlowNodeData.BusinessRuleTask{implementation: attributes["implementation"]}
  end

  defp build_initial_type_data(FlowNodeData.StartEvent, attributes) do
    %FlowNodeData.StartEvent{is_interrupting: attributes["isInterrupting"] != "false"}
  end

  defp build_initial_type_data(mod, _attributes), do: struct(mod)

  defp build_event_definition(:message, attributes) do
    %EventDefinition.Message{message_ref: attributes["messageRef"]}
  end

  defp build_event_definition(:signal, attributes) do
    %EventDefinition.Signal{signal_ref: attributes["signalRef"]}
  end

  defp build_event_definition(:timer, _attributes), do: %EventDefinition.Timer{}

  defp build_event_definition(:error, attributes) do
    %EventDefinition.Error{error_ref: attributes["errorRef"]}
  end

  defp build_event_definition(:escalation, attributes) do
    %EventDefinition.Escalation{escalation_ref: attributes["escalationRef"]}
  end

  defp build_event_definition(:conditional, _attributes), do: %EventDefinition.Conditional{}

  defp build_event_definition(:compensation, attributes) do
    %EventDefinition.Compensation{
      activity_ref: attributes["activityRef"],
      wait_for_completion: attributes["waitForCompletion"] != "false"
    }
  end

  defp build_event_definition(:terminate, _attributes), do: %EventDefinition.Terminate{}
  defp build_event_definition(:cancel, _attributes), do: %EventDefinition.Cancel{}

  defp build_event_definition(:link, attributes) do
    %EventDefinition.Link{link_name: attributes["name"]}
  end

  defp maybe_apply_event_def(%FlowNodeData.StartEvent{} = data, event_def)
       when event_def != nil do
    %FlowNodeData.StartEvent{data | event_definition: event_def}
  end

  defp maybe_apply_event_def(%FlowNodeData.EndEvent{} = data, event_def) when event_def != nil do
    %FlowNodeData.EndEvent{data | event_definition: event_def}
  end

  defp maybe_apply_event_def(%FlowNodeData.IntermediateCatchEvent{} = data, event_def)
       when event_def != nil do
    %FlowNodeData.IntermediateCatchEvent{data | event_definition: event_def}
  end

  defp maybe_apply_event_def(%FlowNodeData.IntermediateThrowEvent{} = data, event_def)
       when event_def != nil do
    %FlowNodeData.IntermediateThrowEvent{data | event_definition: event_def}
  end

  defp maybe_apply_event_def(%FlowNodeData.BoundaryEvent{} = data, event_def)
       when event_def != nil do
    %FlowNodeData.BoundaryEvent{data | event_definition: event_def}
  end

  defp maybe_apply_event_def(data, _event_def), do: data

  defp link_boundary_refs(%BpmnProcess{} = process) do
    boundary_map =
      process.flow_nodes
      |> Enum.filter(&(&1.type == :boundary_event))
      |> Enum.group_by(& &1.type_data.attached_to_ref)

    flow_nodes =
      Enum.map(process.flow_nodes, fn %FlowNode{} = node ->
        refs = boundary_map |> Map.get(node.id, []) |> Enum.map(& &1.id)
        %FlowNode{node | boundary_event_refs: refs}
      end)

    %BpmnProcess{process | flow_nodes: flow_nodes}
  end

  defp apply_default_flows(%BpmnProcess{} = process, defaults) do
    flow_nodes =
      Enum.map(process.flow_nodes, fn %FlowNode{} = node ->
        apply_node_default(node, Map.get(defaults, node.id))
      end)

    sequence_flows =
      Enum.map(process.sequence_flows, fn %SequenceFlow{} = sequence_flow ->
        is_default =
          Enum.any?(Map.values(defaults), fn ref -> ref == sequence_flow.id end)

        %SequenceFlow{sequence_flow | is_default: is_default}
      end)

    %BpmnProcess{process | flow_nodes: flow_nodes, sequence_flows: sequence_flows}
  end

  defp apply_node_default(node, nil), do: node

  defp apply_node_default(%FlowNode{} = node, default_ref) do
    type_data = apply_default_to_type_data(node.type_data, default_ref)
    %FlowNode{node | type_data: type_data}
  end

  defp apply_default_to_type_data(%FlowNodeData.ExclusiveGateway{} = d, ref) do
    %FlowNodeData.ExclusiveGateway{d | default_flow_ref: ref}
  end

  defp apply_default_to_type_data(%FlowNodeData.InclusiveGateway{} = d, ref) do
    %FlowNodeData.InclusiveGateway{d | default_flow_ref: ref}
  end

  defp apply_default_to_type_data(other, _ref), do: other

  defp update_mi(%MultiInstance{} = mi, field, text) when text != "" do
    Map.put(mi, field, text)
  end

  defp update_mi(other, _field, _text), do: other

  defp set_timer_field(%EventDefinition.Timer{} = timer, field, text) when text != "" do
    Map.put(timer, field, text)
  end

  defp set_timer_field(other, _field, _text), do: other

  defp parse_int_attr(string) do
    case Integer.parse(string) do
      {number, _} -> number
      :error -> nil
    end
  end

  # Parses a bare numeric string (e.g. `"92.5"`) into a float, or `nil` when the
  # attribute is absent or unparseable. Used for the definitions-level linter
  # score fields (ESP-D17).
  defp parse_number_or_nil(nil), do: nil

  defp parse_number_or_nil(string) when is_binary(string) do
    case Float.parse(string) do
      {number, _rest} -> number
      :error -> nil
    end
  end

  defp parse_integer_or_nil(nil), do: nil

  defp parse_integer_or_nil(string) when is_binary(string) do
    case Integer.parse(string) do
      {number, _rest} -> number
      :error -> nil
    end
  end

  @result_contract_types [
    FlowNodeData.UserTask,
    FlowNodeData.ServiceTask,
    FlowNodeData.ScriptTask,
    FlowNodeData.BusinessRuleTask,
    FlowNodeData.ReceiveTask,
    FlowNodeData.IntermediateCatchEvent,
    FlowNodeData.BoundaryEvent,
    FlowNodeData.StartEvent,
    FlowNodeData.SubProcess
  ]

  @payload_contract_types [
    FlowNodeData.ServiceTask,
    FlowNodeData.UserTask,
    FlowNodeData.ScriptTask,
    FlowNodeData.BusinessRuleTask,
    FlowNodeData.SendTask,
    FlowNodeData.SubProcess,
    FlowNodeData.IntermediateThrowEvent,
    FlowNodeData.EndEvent
  ]

  defp apply_result_contract(%type{} = data, schema) when type in @result_contract_types do
    %{data | result_contract: schema}
  end

  defp apply_result_contract(other, _schema), do: other

  defp apply_payload_contract(%type{} = data, schema) when type in @payload_contract_types do
    %{data | payload_contract: schema}
  end

  defp apply_payload_contract(other, _schema), do: other

  defp parse_json_text(""), do: nil

  defp parse_json_text(text) do
    case Jason.decode(text) do
      {:ok, result} -> result
      _ -> nil
    end
  end

  defp append_mapping(node_data, field, mapping) do
    if Map.has_key?(node_data, field) do
      Map.update!(node_data, field, &(&1 ++ [mapping]))
    else
      node_data
    end
  end

  defp maybe_flush_subprocess_shell(%{subprocess_stack: [saved | rest], current_node: %FlowNode{id: id}} = state)
       when id == saved.subprocess_node.id do
    updated_saved =
      case state.current_node_data do
        %FlowNodeData.SubProcess{} = data ->
          %{saved | subprocess_node: state.current_node, subprocess_data: data}

        _ ->
          %{saved | subprocess_node: state.current_node}
      end

    %{state | subprocess_stack: [updated_saved | rest]}
  end

  defp maybe_flush_subprocess_shell(state), do: state
end
