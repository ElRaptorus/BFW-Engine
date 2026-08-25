defmodule EvilEngine.BPMN.ValidatorTest do
  use ExUnit.Case, async: true

  alias EvilEngine.BPMN.Model.Definitions
  alias EvilEngine.BPMN.Model.EventDefinition
  alias EvilEngine.BPMN.Model.FlowNode
  alias EvilEngine.BPMN.Model.FlowNodeData
  alias EvilEngine.BPMN.Model.MessageDefinition
  alias EvilEngine.BPMN.Model.MultiInstance
  alias EvilEngine.BPMN.Model.Process, as: BpmnProcess
  alias EvilEngine.BPMN.Model.SequenceFlow
  alias EvilEngine.BPMN.Model.StandardLoop
  alias EvilEngine.BPMN.Parser
  alias EvilEngine.BPMN.Validator

  @fixtures_dir Path.join([__DIR__, "..", "..", "fixtures", "bpmns"])

  defp parse_fixture(name) do
    xml = File.read!(Path.join(@fixtures_dir, name))
    parse_fixture_from_xml(xml)
  end

  defp parse_fixture_from_xml(xml) do
    {:ok, definitions} = Parser.parse(xml)
    definitions
  end

  defp minimal_valid_definitions(overrides) do
    proc_overrides = Keyword.get(overrides, :process, [])
    extra_nodes = Keyword.get(overrides, :extra_nodes, [])
    extra_flows = Keyword.get(overrides, :extra_flows, [])

    base_nodes = [
      %FlowNode{id: "S1", type: :start_event, type_data: %FlowNodeData.StartEvent{}},
      %FlowNode{id: "E1", type: :end_event, type_data: %FlowNodeData.EndEvent{}}
    ]

    base_flows = [
      %SequenceFlow{id: "F1", source_ref: "S1", target_ref: "E1"}
    ]

    proc_fields =
      Keyword.merge(
        [
          id: "P1",
          version: "1.0",
          flow_nodes: base_nodes ++ extra_nodes,
          sequence_flows: base_flows ++ extra_flows
        ],
        proc_overrides
      )

    %Definitions{raw_xml: "", processes: [struct!(BpmnProcess, proc_fields)]}
  end

  # Asserts that no validation violation carries the given code. The overall
  # validation may still fail on unrelated structural checks (orphan nodes,
  # unreachable end events), so we assert the absence of the specific code
  # rather than an overall `{:ok, _}`.
  defp refute_violation_code(definitions, code) do
    case Validator.validate(definitions) do
      {:ok, _} ->
        :ok

      {:error, violations} ->
        refute Enum.any?(violations, fn {c, _} -> c == code end),
               "expected no #{inspect(code)} violation, got: #{inspect(violations)}"
    end
  end

  defp assert_violation_code(definitions, code) do
    case Validator.validate(definitions) do
      {:ok, _} ->
        flunk("expected #{inspect(code)} violation but validation passed")

      {:error, violations} ->
        assert Enum.any?(violations, fn {c, _} -> c == code end),
               "expected #{inspect(code)} violation, got: #{inspect(violations)}"
    end
  end

  # -------------------------------------------------------------------------
  # Happy paths
  # -------------------------------------------------------------------------

  describe "validate/1 — happy paths" do
    test "minimal valid BPMN passes" do
      definitions = parse_fixture("minimal_valid.bpmn")
      assert {:ok, ^definitions} = Validator.validate(definitions)
    end

    test "multi-process with extensions passes" do
      definitions = parse_fixture("multi_process.bpmn")
      assert {:ok, ^definitions} = Validator.validate(definitions)
    end

    test "non-executable processes are skipped" do
      definitions = parse_fixture("multi_process.bpmn")
      helper = Enum.find(definitions.processes, &(&1.id == "Process_Helper"))
      refute helper.is_executable
      assert {:ok, _} = Validator.validate(definitions)
    end

    test "broken non-executable process does not cause validation failure" do
      broken_non_exec = %BpmnProcess{
        id: "BrokenHelper",
        name: "Broken",
        is_executable: false,
        version: nil,
        flow_nodes: [],
        sequence_flows: [],
        lanes: [],
        data_objects: [],
        correlation_key: nil,
        extensions: []
      }

      valid_definitions = minimal_valid_definitions([])

      definitions = %{
        valid_definitions
        | processes: valid_definitions.processes ++ [broken_non_exec]
      }

      assert {:ok, _} = Validator.validate(definitions)
    end
  end

  # -------------------------------------------------------------------------
  # Process-level checks
  # -------------------------------------------------------------------------

  describe "validate/1 — missing version" do
    test "rejects process without evil:version" do
      definitions = parse_fixture("missing_version.bpmn")
      assert {:error, violations} = Validator.validate(definitions)
      assert Enum.any?(violations, fn {code, _} -> code == :missing_version end)
    end

    test "error message is human-readable" do
      definitions = parse_fixture("missing_version.bpmn")
      {:error, violations} = Validator.validate(definitions)
      {_, message} = Enum.find(violations, fn {c, _} -> c == :missing_version end)
      assert message =~ "Process"
      assert message =~ "missing required property"
      assert message =~ "version"
    end
  end

  describe "validate/1 — blank version" do
    test "rejects process with blank (empty string) version" do
      definitions = minimal_valid_definitions(process: [version: ""])

      assert {:error, violations} = Validator.validate(definitions)
      assert Enum.any?(violations, fn {code, _} -> code == :blank_version end)
    end
  end

  describe "validate/1 — missing start/end events" do
    test "rejects process without start event" do
      definitions = parse_fixture("missing_start_event.bpmn")
      assert {:error, violations} = Validator.validate(definitions)
      assert Enum.any?(violations, fn {code, _} -> code == :missing_start_event end)
    end

    test "rejects process without end event" do
      definitions = %Definitions{
        raw_xml: "",
        processes: [
          %BpmnProcess{
            id: "P1",
            version: "1.0",
            flow_nodes: [
              %FlowNode{id: "S1", type: :start_event, type_data: %FlowNodeData.StartEvent{}}
            ]
          }
        ]
      }

      assert {:error, violations} = Validator.validate(definitions)
      assert Enum.any?(violations, fn {code, _} -> code == :missing_end_event end)
    end
  end

  # -------------------------------------------------------------------------
  # Essential property checks
  # -------------------------------------------------------------------------

  describe "validate/1 — essential properties" do
    test "rejects flow node with blank id" do
      definitions = %Definitions{
        raw_xml: "",
        processes: [
          %BpmnProcess{
            id: "P1",
            version: "1.0",
            flow_nodes: [
              %FlowNode{id: "", type: :start_event, type_data: %FlowNodeData.StartEvent{}},
              %FlowNode{id: "E1", type: :end_event, type_data: %FlowNodeData.EndEvent{}}
            ],
            sequence_flows: [%SequenceFlow{id: "F1", source_ref: "", target_ref: "E1"}]
          }
        ]
      }

      assert {:error, violations} = Validator.validate(definitions)
      assert Enum.any?(violations, fn {code, _} -> code == :missing_node_id end)
    end

    test "rejects sequence flow with blank sourceRef" do
      definitions =
        minimal_valid_definitions(
          extra_flows: [%SequenceFlow{id: "Bad_F", source_ref: "", target_ref: "E1"}]
        )

      assert {:error, violations} = Validator.validate(definitions)

      assert Enum.any?(violations, fn {code, message} ->
               code == :incomplete_sequence_flow and message =~ "sourceRef"
             end)
    end

    test "error message lists all missing properties together" do
      definitions = %Definitions{
        raw_xml: "",
        processes: [
          %BpmnProcess{
            id: "P1",
            version: "1.0",
            flow_nodes: [
              %FlowNode{id: "S1", type: :start_event, type_data: %FlowNodeData.StartEvent{}},
              %FlowNode{id: "E1", type: :end_event, type_data: %FlowNodeData.EndEvent{}}
            ],
            sequence_flows: [
              %SequenceFlow{id: "F1", source_ref: "S1", target_ref: "E1"},
              %SequenceFlow{id: "", source_ref: "", target_ref: ""}
            ]
          }
        ]
      }

      assert {:error, violations} = Validator.validate(definitions)

      bad_sequence_flow =
        Enum.find(violations, fn {code, _} -> code == :incomplete_sequence_flow end)

      assert bad_sequence_flow != nil
      {_, message} = bad_sequence_flow
      assert message =~ "id"
      assert message =~ "sourceRef"
      assert message =~ "targetRef"
    end
  end

  # -------------------------------------------------------------------------
  # Dangling references
  # -------------------------------------------------------------------------

  describe "validate/1 — dangling references" do
    test "catches dangling sequence flow target ref" do
      definitions = parse_fixture("dangling_refs.bpmn")
      assert {:error, violations} = Validator.validate(definitions)

      assert Enum.any?(violations, fn {code, message} ->
               code == :dangling_target_ref and message =~ "NonExistent_Node"
             end)
    end

    test "catches dangling data object reference" do
      definitions = parse_fixture("dangling_refs.bpmn")
      assert {:error, violations} = Validator.validate(definitions)

      assert Enum.any?(violations, fn {code, message} ->
               code == :dangling_data_object_ref and message =~ "DO_NonExistent"
             end)
    end

    test "catches dangling message ref on start event" do
      definitions = parse_fixture("dangling_refs.bpmn")
      assert {:error, violations} = Validator.validate(definitions)

      assert Enum.any?(violations, fn {code, message} ->
               code == :dangling_message_ref and message =~ "Msg_NonExistent"
             end)
    end

    test "catches dangling source ref" do
      definitions =
        minimal_valid_definitions(
          extra_flows: [
            %SequenceFlow{id: "F_bad", source_ref: "NoSuchNode", target_ref: "E1"}
          ]
        )

      assert {:error, violations} = Validator.validate(definitions)

      assert Enum.any?(violations, fn {code, message} ->
               code == :dangling_source_ref and message =~ "NoSuchNode"
             end)
    end

    test "catches dangling signal ref" do
      definitions =
        minimal_valid_definitions(
          extra_nodes: [
            %FlowNode{
              id: "ITE1",
              type: :intermediate_throw_event,
              type_data: %FlowNodeData.IntermediateThrowEvent{
                event_definition: %EventDefinition.Signal{signal_ref: "Sig_Missing"}
              }
            }
          ],
          extra_flows: [
            %SequenceFlow{id: "F2", source_ref: "S1", target_ref: "ITE1"},
            %SequenceFlow{id: "F3", source_ref: "ITE1", target_ref: "E1"}
          ]
        )

      assert {:error, violations} = Validator.validate(definitions)

      assert Enum.any?(violations, fn {code, message} ->
               code == :dangling_signal_ref and message =~ "Sig_Missing"
             end)
    end

    test "catches dangling error ref on end event" do
      definitions =
        minimal_valid_definitions(
          process: [
            flow_nodes: [
              %FlowNode{id: "S1", type: :start_event, type_data: %FlowNodeData.StartEvent{}},
              %FlowNode{
                id: "E1",
                type: :end_event,
                type_data: %FlowNodeData.EndEvent{
                  event_definition: %EventDefinition.Error{error_ref: "Err_Missing"}
                }
              }
            ],
            sequence_flows: [%SequenceFlow{id: "F1", source_ref: "S1", target_ref: "E1"}]
          ]
        )

      assert {:error, violations} = Validator.validate(definitions)

      assert Enum.any?(violations, fn {code, _} -> code == :dangling_error_ref end)
    end

    test "catches dangling escalation ref on throw event" do
      definitions =
        minimal_valid_definitions(
          extra_nodes: [
            %FlowNode{
              id: "ITE1",
              type: :intermediate_throw_event,
              type_data: %FlowNodeData.IntermediateThrowEvent{
                event_definition: %EventDefinition.Escalation{escalation_ref: "Esc_Missing"}
              }
            }
          ],
          extra_flows: [
            %SequenceFlow{id: "F2", source_ref: "S1", target_ref: "ITE1"},
            %SequenceFlow{id: "F3", source_ref: "ITE1", target_ref: "E1"}
          ]
        )

      assert {:error, violations} = Validator.validate(definitions)

      assert Enum.any?(violations, fn {code, _} -> code == :dangling_escalation_ref end)
    end

    test "catches dangling message ref on SendTask" do
      definitions =
        minimal_valid_definitions(
          extra_nodes: [
            %FlowNode{
              id: "Send1",
              type: :send_task,
              type_data: %FlowNodeData.SendTask{message_ref: "Msg_Missing"}
            }
          ],
          extra_flows: [
            %SequenceFlow{id: "F2", source_ref: "S1", target_ref: "Send1"},
            %SequenceFlow{id: "F3", source_ref: "Send1", target_ref: "E1"}
          ]
        )

      assert {:error, violations} = Validator.validate(definitions)

      assert Enum.any?(violations, fn {code, message} ->
               code == :dangling_message_ref and message =~ "Msg_Missing"
             end)
    end

    test "catches dangling message ref on ReceiveTask" do
      definitions =
        minimal_valid_definitions(
          extra_nodes: [
            %FlowNode{
              id: "Recv1",
              type: :receive_task,
              type_data: %FlowNodeData.ReceiveTask{message_ref: "Msg_Missing"}
            }
          ],
          extra_flows: [
            %SequenceFlow{id: "F2", source_ref: "S1", target_ref: "Recv1"},
            %SequenceFlow{id: "F3", source_ref: "Recv1", target_ref: "E1"}
          ]
        )

      assert {:error, violations} = Validator.validate(definitions)

      assert Enum.any?(violations, fn {code, message} ->
               code == :dangling_message_ref and message =~ "Msg_Missing"
             end)
    end
  end

  # -------------------------------------------------------------------------
  # Orphan node checks
  # -------------------------------------------------------------------------

  describe "validate/1 — orphan nodes" do
    test "detects a task not connected to any sequence flow" do
      definitions =
        minimal_valid_definitions(
          extra_nodes: [
            %FlowNode{id: "Orphan1", type: :task, type_data: %FlowNodeData.Task{}}
          ]
        )

      assert {:error, violations} = Validator.validate(definitions)

      assert Enum.any?(violations, fn {code, message} ->
               code == :orphan_node and message =~ "Orphan1"
             end)
    end

    test "does not flag start/end/boundary events as orphans" do
      definitions = minimal_valid_definitions([])
      assert {:ok, _} = Validator.validate(definitions)
    end

    test "does not flag link throw/catch events without outgoing/incoming flows as orphans" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
                        xmlns:evil="https://evilengine.dev/schema/bpmn"
                        id="Defs_1">
        <bpmn:process id="P1" name="Link Orphan Exemption" isExecutable="true">
          <bpmn:extensionElements><evil:version>1.0.0</evil:version></bpmn:extensionElements>
          <bpmn:startEvent id="Start_1"><bpmn:outgoing>F1</bpmn:outgoing></bpmn:startEvent>
          <bpmn:task id="Task_1" name="Work">
            <bpmn:incoming>F1</bpmn:incoming>
            <bpmn:outgoing>F2</bpmn:outgoing>
          </bpmn:task>
          <bpmn:intermediateThrowEvent id="Link_Throw" name="Jump Out">
            <bpmn:linkEventDefinition name="jump-target"/>
            <bpmn:incoming>F2</bpmn:incoming>
          </bpmn:intermediateThrowEvent>
          <bpmn:intermediateCatchEvent id="Link_Catch" name="Jump In">
            <bpmn:linkEventDefinition name="jump-target"/>
            <bpmn:outgoing>F3</bpmn:outgoing>
          </bpmn:intermediateCatchEvent>
          <bpmn:endEvent id="End_1"><bpmn:incoming>F3</bpmn:incoming></bpmn:endEvent>
          <bpmn:sequenceFlow id="F1" sourceRef="Start_1" targetRef="Task_1"/>
          <bpmn:sequenceFlow id="F2" sourceRef="Task_1" targetRef="Link_Throw"/>
          <bpmn:sequenceFlow id="F3" sourceRef="Link_Catch" targetRef="End_1"/>
        </bpmn:process>
      </bpmn:definitions>
      """

      definitions = parse_fixture_from_xml(xml)
      assert {:ok, _} = Validator.validate(definitions)
    end
  end

  # -------------------------------------------------------------------------
  # Start/end flow direction checks
  # -------------------------------------------------------------------------

  describe "validate/1 — start/end flow direction" do
    test "rejects start event with incoming sequence flow" do
      definitions =
        minimal_valid_definitions(
          extra_flows: [
            %SequenceFlow{id: "F_bad", source_ref: "E1", target_ref: "S1"}
          ]
        )

      assert {:error, violations} = Validator.validate(definitions)

      assert Enum.any?(violations, fn {code, message} ->
               code == :start_has_incoming and message =~ "S1"
             end)
    end

    test "rejects end event with outgoing sequence flow" do
      definitions =
        minimal_valid_definitions(
          extra_nodes: [
            %FlowNode{id: "T1", type: :task, type_data: %FlowNodeData.Task{}}
          ],
          extra_flows: [
            %SequenceFlow{id: "F_out", source_ref: "E1", target_ref: "T1"},
            %SequenceFlow{id: "F_in", source_ref: "T1", target_ref: "E1"}
          ]
        )

      assert {:error, violations} = Validator.validate(definitions)

      assert Enum.any?(violations, fn {code, message} ->
               code == :end_has_outgoing and message =~ "E1"
             end)
    end
  end

  # -------------------------------------------------------------------------
  # Event-definition/position combos
  # -------------------------------------------------------------------------

  describe "validate/1 — invalid event-definition position" do
    test "rejects timer inside end event" do
      definitions =
        minimal_valid_definitions(
          process: [
            flow_nodes: [
              %FlowNode{id: "S1", type: :start_event, type_data: %FlowNodeData.StartEvent{}},
              %FlowNode{
                id: "End_Bad",
                type: :end_event,
                type_data: %FlowNodeData.EndEvent{
                  event_definition: %EventDefinition.Timer{time_duration: "PT1H"}
                }
              }
            ],
            sequence_flows: [%SequenceFlow{id: "F1", source_ref: "S1", target_ref: "End_Bad"}]
          ]
        )

      assert {:error, violations} = Validator.validate(definitions)
      assert Enum.any?(violations, fn {code, _} -> code == :invalid_event_position end)
    end

    test "error message names both the position and the definition" do
      definitions =
        minimal_valid_definitions(
          process: [
            flow_nodes: [
              %FlowNode{id: "S1", type: :start_event, type_data: %FlowNodeData.StartEvent{}},
              %FlowNode{
                id: "End_Bad",
                type: :end_event,
                type_data: %FlowNodeData.EndEvent{
                  event_definition: %EventDefinition.Timer{time_duration: "PT1H"}
                }
              }
            ],
            sequence_flows: [%SequenceFlow{id: "F1", source_ref: "S1", target_ref: "End_Bad"}]
          ]
        )

      {:error, violations} = Validator.validate(definitions)
      {_, message} = Enum.find(violations, fn {c, _} -> c == :invalid_event_position end)
      assert message =~ "EndEvent"
      assert message =~ "Timer"
    end

    test "rejects error event definition on start event" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
                        xmlns:evil="https://evilengine.dev/schema/bpmn"
                        id="Defs_1">
        <bpmn:error id="Err_1" name="ValidationError" errorCode="VALIDATION_FAILED"/>
        <bpmn:process id="P1" name="Invalid Start Error" isExecutable="true">
          <bpmn:extensionElements><evil:version>1.0.0</evil:version></bpmn:extensionElements>
          <bpmn:startEvent id="Start_Bad" name="Bad Start">
            <bpmn:errorEventDefinition errorRef="Err_1"/>
            <bpmn:outgoing>F1</bpmn:outgoing>
          </bpmn:startEvent>
          <bpmn:endEvent id="End_1"><bpmn:incoming>F1</bpmn:incoming></bpmn:endEvent>
          <bpmn:sequenceFlow id="F1" sourceRef="Start_Bad" targetRef="End_1"/>
        </bpmn:process>
      </bpmn:definitions>
      """

      definitions = parse_fixture_from_xml(xml)
      assert {:error, violations} = Validator.validate(definitions)

      assert Enum.any?(violations, fn {code, message} ->
               code == :invalid_event_position and message =~ "StartEvent" and message =~ "Error"
             end)
    end

    test "rejects timer event definition on intermediate throw event" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
                        xmlns:evil="https://evilengine.dev/schema/bpmn"
                        id="Defs_1">
        <bpmn:process id="P1" name="Invalid Throw Timer" isExecutable="true">
          <bpmn:extensionElements><evil:version>1.0.0</evil:version></bpmn:extensionElements>
          <bpmn:startEvent id="Start_1"><bpmn:outgoing>F1</bpmn:outgoing></bpmn:startEvent>
          <bpmn:intermediateThrowEvent id="Throw_Bad" name="Bad Throw">
            <bpmn:timerEventDefinition>
              <bpmn:timeDuration>PT1H</bpmn:timeDuration>
            </bpmn:timerEventDefinition>
            <bpmn:incoming>F1</bpmn:incoming>
            <bpmn:outgoing>F2</bpmn:outgoing>
          </bpmn:intermediateThrowEvent>
          <bpmn:endEvent id="End_1"><bpmn:incoming>F2</bpmn:incoming></bpmn:endEvent>
          <bpmn:sequenceFlow id="F1" sourceRef="Start_1" targetRef="Throw_Bad"/>
          <bpmn:sequenceFlow id="F2" sourceRef="Throw_Bad" targetRef="End_1"/>
        </bpmn:process>
      </bpmn:definitions>
      """

      definitions = parse_fixture_from_xml(xml)
      assert {:error, violations} = Validator.validate(definitions)

      assert Enum.any?(violations, fn {code, message} ->
               code == :invalid_event_position and
                 message =~ "IntermediateThrowEvent" and message =~ "Timer"
             end)
    end

    test "rejects cancel event definition on start event" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
                        xmlns:evil="https://evilengine.dev/schema/bpmn"
                        id="Defs_1">
        <bpmn:process id="P1" name="Invalid Start Cancel" isExecutable="true">
          <bpmn:extensionElements><evil:version>1.0.0</evil:version></bpmn:extensionElements>
          <bpmn:startEvent id="Start_Bad" name="Bad Start">
            <bpmn:cancelEventDefinition/>
            <bpmn:outgoing>F1</bpmn:outgoing>
          </bpmn:startEvent>
          <bpmn:endEvent id="End_1"><bpmn:incoming>F1</bpmn:incoming></bpmn:endEvent>
          <bpmn:sequenceFlow id="F1" sourceRef="Start_Bad" targetRef="End_1"/>
        </bpmn:process>
      </bpmn:definitions>
      """

      definitions = parse_fixture_from_xml(xml)
      assert {:error, violations} = Validator.validate(definitions)

      assert Enum.any?(violations, fn {code, message} ->
               code == :invalid_event_position and message =~ "StartEvent" and message =~ "Cancel"
             end)
    end
  end

  # -------------------------------------------------------------------------
  # Type-specific activity checks
  # -------------------------------------------------------------------------

  describe "validate/1 — CallActivity completeness" do
    test "rejects CallActivity without calledElement" do
      definitions =
        minimal_valid_definitions(
          extra_nodes: [
            %FlowNode{id: "CA1", type: :call_activity, type_data: %FlowNodeData.CallActivity{}}
          ],
          extra_flows: [
            %SequenceFlow{id: "F2", source_ref: "S1", target_ref: "CA1"},
            %SequenceFlow{id: "F3", source_ref: "CA1", target_ref: "E1"}
          ]
        )

      assert {:error, violations} = Validator.validate(definitions)

      {_, message} = Enum.find(violations, fn {c, _} -> c == :incomplete_flow_node end)
      assert message =~ "CallActivity"
      assert message =~ "'CA1'"
      assert message =~ "calledElement"
    end

    test "passes when calledElement is set" do
      definitions =
        minimal_valid_definitions(
          extra_nodes: [
            %FlowNode{
              id: "CA1",
              type: :call_activity,
              type_data: %FlowNodeData.CallActivity{called_element: "OtherProcess"}
            }
          ],
          extra_flows: [
            %SequenceFlow{id: "F2", source_ref: "S1", target_ref: "CA1"},
            %SequenceFlow{id: "F3", source_ref: "CA1", target_ref: "E1"}
          ]
        )

      assert {:ok, _} = Validator.validate(definitions)
    end
  end

  describe "validate/1 — ServiceTask completeness" do
    test "rejects ServiceTask without implementation" do
      definitions =
        minimal_valid_definitions(
          extra_nodes: [
            %FlowNode{id: "ST1", type: :service_task, type_data: %FlowNodeData.ServiceTask{}}
          ],
          extra_flows: [
            %SequenceFlow{id: "F2", source_ref: "S1", target_ref: "ST1"},
            %SequenceFlow{id: "F3", source_ref: "ST1", target_ref: "E1"}
          ]
        )

      assert {:error, violations} = Validator.validate(definitions)

      {_, message} = Enum.find(violations, fn {c, _} -> c == :incomplete_flow_node end)
      assert message =~ "ServiceTask"
      assert message =~ "'ST1'"
      assert message =~ "implementation"
    end
  end

  describe "validate/1 — SendTask completeness" do
    test "rejects SendTask without messageRef" do
      definitions =
        minimal_valid_definitions(
          extra_nodes: [
            %FlowNode{id: "Send1", type: :send_task, type_data: %FlowNodeData.SendTask{}}
          ],
          extra_flows: [
            %SequenceFlow{id: "F2", source_ref: "S1", target_ref: "Send1"},
            %SequenceFlow{id: "F3", source_ref: "Send1", target_ref: "E1"}
          ]
        )

      assert {:error, violations} = Validator.validate(definitions)

      {_, message} = Enum.find(violations, fn {c, _} -> c == :incomplete_flow_node end)
      assert message =~ "SendTask"
      assert message =~ "messageRef"
    end
  end

  describe "validate/1 — ReceiveTask completeness" do
    test "rejects ReceiveTask without messageRef" do
      definitions =
        minimal_valid_definitions(
          extra_nodes: [
            %FlowNode{id: "Recv1", type: :receive_task, type_data: %FlowNodeData.ReceiveTask{}}
          ],
          extra_flows: [
            %SequenceFlow{id: "F2", source_ref: "S1", target_ref: "Recv1"},
            %SequenceFlow{id: "F3", source_ref: "Recv1", target_ref: "E1"}
          ]
        )

      assert {:error, violations} = Validator.validate(definitions)

      {_, message} = Enum.find(violations, fn {c, _} -> c == :incomplete_flow_node end)
      assert message =~ "ReceiveTask"
      assert message =~ "messageRef"
    end
  end

  describe "validate/1 — ScriptTask completeness" do
    test "rejects ScriptTask without script and scriptRef" do
      definitions =
        minimal_valid_definitions(
          extra_nodes: [
            %FlowNode{id: "Scr1", type: :script_task, type_data: %FlowNodeData.ScriptTask{}}
          ],
          extra_flows: [
            %SequenceFlow{id: "F2", source_ref: "S1", target_ref: "Scr1"},
            %SequenceFlow{id: "F3", source_ref: "Scr1", target_ref: "E1"}
          ]
        )

      assert {:error, violations} = Validator.validate(definitions)

      {_, message} = Enum.find(violations, fn {c, _} -> c == :incomplete_flow_node end)
      assert message =~ "ScriptTask"
      assert message =~ "script or scriptRef"
    end

    test "passes when inline script is set" do
      definitions =
        minimal_valid_definitions(
          extra_nodes: [
            %FlowNode{
              id: "Scr1",
              type: :script_task,
              type_data: %FlowNodeData.ScriptTask{script: "1 + 1"}
            }
          ],
          extra_flows: [
            %SequenceFlow{id: "F2", source_ref: "S1", target_ref: "Scr1"},
            %SequenceFlow{id: "F3", source_ref: "Scr1", target_ref: "E1"}
          ]
        )

      assert {:ok, _} = Validator.validate(definitions)
    end
  end

  describe "validate/1 — BusinessRuleTask completeness" do
    test "rejects BusinessRuleTask without implementation" do
      definitions =
        minimal_valid_definitions(
          extra_nodes: [
            %FlowNode{
              id: "BR1",
              type: :business_rule_task,
              type_data: %FlowNodeData.BusinessRuleTask{}
            }
          ],
          extra_flows: [
            %SequenceFlow{id: "F2", source_ref: "S1", target_ref: "BR1"},
            %SequenceFlow{id: "F3", source_ref: "BR1", target_ref: "E1"}
          ]
        )

      assert {:error, violations} = Validator.validate(definitions)

      {_, message} = Enum.find(violations, fn {c, _} -> c == :incomplete_flow_node end)
      assert message =~ "BusinessRuleTask"
      assert message =~ "implementation"
    end

    test "rejects unrecognized implementation value" do
      definitions =
        minimal_valid_definitions(
          extra_nodes: [
            %FlowNode{
              id: "BR1",
              type: :business_rule_task,
              type_data: %FlowNodeData.BusinessRuleTask{implementation: "invalid"}
            }
          ],
          extra_flows: [
            %SequenceFlow{id: "F2", source_ref: "S1", target_ref: "BR1"},
            %SequenceFlow{id: "F3", source_ref: "BR1", target_ref: "E1"}
          ]
        )

      assert {:error, violations} = Validator.validate(definitions)

      {code, message} =
        Enum.find(violations, fn {c, _} -> c == :invalid_brt_implementation end)

      assert code == :invalid_brt_implementation
      assert message =~ "unrecognized implementation='invalid'"
    end

    test "rejects implementation='feel' without script" do
      definitions =
        minimal_valid_definitions(
          extra_nodes: [
            %FlowNode{
              id: "BR1",
              type: :business_rule_task,
              type_data: %FlowNodeData.BusinessRuleTask{implementation: "feel"}
            }
          ],
          extra_flows: [
            %SequenceFlow{id: "F2", source_ref: "S1", target_ref: "BR1"},
            %SequenceFlow{id: "F3", source_ref: "BR1", target_ref: "E1"}
          ]
        )

      assert {:error, violations} = Validator.validate(definitions)

      {_, message} = Enum.find(violations, fn {c, _} -> c == :incomplete_flow_node end)
      assert message =~ "implementation='feel'"
      assert message =~ "script"
    end

    test "rejects implementation='dmn' without decision_ref" do
      definitions =
        minimal_valid_definitions(
          extra_nodes: [
            %FlowNode{
              id: "BR1",
              type: :business_rule_task,
              type_data: %FlowNodeData.BusinessRuleTask{implementation: "dmn"}
            }
          ],
          extra_flows: [
            %SequenceFlow{id: "F2", source_ref: "S1", target_ref: "BR1"},
            %SequenceFlow{id: "F3", source_ref: "BR1", target_ref: "E1"}
          ]
        )

      assert {:error, violations} = Validator.validate(definitions)

      {_, message} = Enum.find(violations, fn {c, _} -> c == :incomplete_flow_node end)
      assert message =~ "implementation='dmn'"
      assert message =~ "decisionRef"
    end

    test "rejects implementation='plugin' as unrecognized" do
      definitions =
        minimal_valid_definitions(
          extra_nodes: [
            %FlowNode{
              id: "BR1",
              type: :business_rule_task,
              type_data: %FlowNodeData.BusinessRuleTask{implementation: "plugin"}
            }
          ],
          extra_flows: [
            %SequenceFlow{id: "F2", source_ref: "S1", target_ref: "BR1"},
            %SequenceFlow{id: "F3", source_ref: "BR1", target_ref: "E1"}
          ]
        )

      assert {:error, violations} = Validator.validate(definitions)

      {code, message} =
        Enum.find(violations, fn {c, _} -> c == :invalid_brt_implementation end)

      assert code == :invalid_brt_implementation
      assert message =~ "unrecognized implementation='plugin'"
    end

    test "accepts valid feel mode with script" do
      definitions =
        minimal_valid_definitions(
          extra_nodes: [
            %FlowNode{
              id: "BR1",
              type: :business_rule_task,
              type_data: %FlowNodeData.BusinessRuleTask{
                implementation: "feel",
                script: "1 + 1"
              }
            }
          ],
          extra_flows: [
            %SequenceFlow{id: "F2", source_ref: "S1", target_ref: "BR1"},
            %SequenceFlow{id: "F3", source_ref: "BR1", target_ref: "E1"}
          ]
        )

      assert {:ok, _} = Validator.validate(definitions)
    end

    test "rejects plugin mode even with rule_ref" do
      definitions =
        minimal_valid_definitions(
          extra_nodes: [
            %FlowNode{
              id: "BR1",
              type: :business_rule_task,
              type_data: %FlowNodeData.BusinessRuleTask{
                implementation: "plugin",
                rule_ref: "my_rule"
              }
            }
          ],
          extra_flows: [
            %SequenceFlow{id: "F2", source_ref: "S1", target_ref: "BR1"},
            %SequenceFlow{id: "F3", source_ref: "BR1", target_ref: "E1"}
          ]
        )

      assert {:error, violations} = Validator.validate(definitions)

      {code, _message} =
        Enum.find(violations, fn {c, _} -> c == :invalid_brt_implementation end)

      assert code == :invalid_brt_implementation
    end

    test "accepts valid dmn mode with decision_ref" do
      definitions =
        minimal_valid_definitions(
          extra_nodes: [
            %FlowNode{
              id: "BR1",
              type: :business_rule_task,
              type_data: %FlowNodeData.BusinessRuleTask{
                implementation: "dmn",
                decision_ref: "discount-rules"
              }
            }
          ],
          extra_flows: [
            %SequenceFlow{id: "F2", source_ref: "S1", target_ref: "BR1"},
            %SequenceFlow{id: "F3", source_ref: "BR1", target_ref: "E1"}
          ]
        )

      assert {:ok, _} = Validator.validate(definitions)
    end
  end

  # -------------------------------------------------------------------------
  # Gateway checks
  # -------------------------------------------------------------------------

  describe "validate/1 — ComplexGateway split/join rules" do
    test "rejects a Complex Join without activationCondition" do
      definitions =
        minimal_valid_definitions(
          extra_nodes: [
            %FlowNode{id: "T1", type: :task, type_data: %FlowNodeData.Task{}},
            %FlowNode{id: "T2", type: :task, type_data: %FlowNodeData.Task{}},
            %FlowNode{
              id: "CGJoin",
              type: :complex_gateway,
              type_data: %FlowNodeData.ComplexGateway{}
            }
          ],
          extra_flows: [
            %SequenceFlow{id: "F2", source_ref: "S1", target_ref: "T1"},
            %SequenceFlow{id: "F3", source_ref: "S1", target_ref: "T2"},
            %SequenceFlow{id: "Fa", source_ref: "T1", target_ref: "CGJoin"},
            %SequenceFlow{id: "Fb", source_ref: "T2", target_ref: "CGJoin"},
            %SequenceFlow{id: "Fc", source_ref: "CGJoin", target_ref: "E1"}
          ]
        )

      assert {:error, violations} = Validator.validate(definitions)

      {_, message} =
        Enum.find(violations, fn {c, _} -> c == :complex_gateway_join_missing_activation_condition end)

      assert message =~ "ComplexGateway 'CGJoin'"
      assert message =~ "activationCondition"
    end

    test "accepts a Complex Join with a non-blank activationCondition" do
      definitions =
        minimal_valid_definitions(
          extra_nodes: [
            %FlowNode{id: "T1", type: :task, type_data: %FlowNodeData.Task{}},
            %FlowNode{id: "T2", type: :task, type_data: %FlowNodeData.Task{}},
            %FlowNode{
              id: "CGJoin",
              type: :complex_gateway,
              type_data: %FlowNodeData.ComplexGateway{activation_condition: "activatedCount >= 2"}
            }
          ],
          extra_flows: [
            %SequenceFlow{id: "F2", source_ref: "S1", target_ref: "T1"},
            %SequenceFlow{id: "F3", source_ref: "S1", target_ref: "T2"},
            %SequenceFlow{id: "Fa", source_ref: "T1", target_ref: "CGJoin"},
            %SequenceFlow{id: "Fb", source_ref: "T2", target_ref: "CGJoin"},
            %SequenceFlow{id: "Fc", source_ref: "CGJoin", target_ref: "E1"}
          ]
        )

      refute_violation_code(definitions, :complex_gateway_join_missing_activation_condition)
    end

    test "accepts a Complex Split with an unconditional non-default outgoing flow" do
      definitions =
        minimal_valid_definitions(
          extra_nodes: [
            %FlowNode{
              id: "CGSplit",
              type: :complex_gateway,
              type_data: %FlowNodeData.ComplexGateway{}
            },
            %FlowNode{id: "T1", type: :task, type_data: %FlowNodeData.Task{}},
            %FlowNode{id: "T2", type: :task, type_data: %FlowNodeData.Task{}}
          ],
          extra_flows: [
            %SequenceFlow{id: "Fin", source_ref: "S1", target_ref: "CGSplit"},
            %SequenceFlow{
              id: "Fa",
              source_ref: "CGSplit",
              target_ref: "T1",
              condition_expression: "token.a = true"
            },
            %SequenceFlow{id: "Fb", source_ref: "CGSplit", target_ref: "T2"}
          ]
        )

      violations =
        case Validator.validate(definitions) do
          {:ok, _definitions} -> []
          {:error, list} -> list
        end

      refute Enum.any?(violations, fn {code, _message} ->
               code == :complex_gateway_unconditional_flow
             end)
    end

    test "accepts a Complex Split whose outgoing flows are all conditional or default" do
      definitions =
        minimal_valid_definitions(
          extra_nodes: [
            %FlowNode{
              id: "CGSplit",
              type: :complex_gateway,
              type_data: %FlowNodeData.ComplexGateway{}
            },
            %FlowNode{id: "T1", type: :task, type_data: %FlowNodeData.Task{}},
            %FlowNode{id: "T2", type: :task, type_data: %FlowNodeData.Task{}}
          ],
          extra_flows: [
            %SequenceFlow{id: "Fin", source_ref: "S1", target_ref: "CGSplit"},
            %SequenceFlow{
              id: "Fa",
              source_ref: "CGSplit",
              target_ref: "T1",
              condition_expression: "token.a = true"
            },
            %SequenceFlow{id: "Fb", source_ref: "CGSplit", target_ref: "T2", is_default: true}
          ]
        )

      refute_violation_code(definitions, :complex_gateway_unconditional_flow)
    end

    test "rejects a mixed Complex Gateway (many incoming AND many outgoing)" do
      definitions =
        minimal_valid_definitions(
          extra_nodes: [
            %FlowNode{id: "T1", type: :task, type_data: %FlowNodeData.Task{}},
            %FlowNode{id: "T2", type: :task, type_data: %FlowNodeData.Task{}},
            %FlowNode{id: "T3", type: :task, type_data: %FlowNodeData.Task{}},
            %FlowNode{id: "T4", type: :task, type_data: %FlowNodeData.Task{}},
            %FlowNode{
              id: "CGMixed",
              type: :complex_gateway,
              type_data: %FlowNodeData.ComplexGateway{activation_condition: "activatedCount >= 1"}
            }
          ],
          extra_flows: [
            %SequenceFlow{id: "Fin1", source_ref: "T1", target_ref: "CGMixed"},
            %SequenceFlow{id: "Fin2", source_ref: "T2", target_ref: "CGMixed"},
            %SequenceFlow{id: "Fout1", source_ref: "CGMixed", target_ref: "T3"},
            %SequenceFlow{id: "Fout2", source_ref: "CGMixed", target_ref: "T4"}
          ]
        )

      assert {:error, violations} = Validator.validate(definitions)

      {_, message} = Enum.find(violations, fn {c, _} -> c == :complex_gateway_mixed end)

      assert message =~ "ComplexGateway 'CGMixed'"
      assert message =~ "mixed gateway"
    end
  end

  describe "validate/1 — ComplexGateway pairing / SESE region rules" do
    test "rejects a Complex Join that has no dominating Complex Split" do
      definitions =
        minimal_valid_definitions(
          extra_nodes: [
            %FlowNode{id: "T1", type: :task, type_data: %FlowNodeData.Task{}},
            %FlowNode{id: "T2", type: :task, type_data: %FlowNodeData.Task{}},
            %FlowNode{
              id: "CGJoin",
              type: :complex_gateway,
              type_data: %FlowNodeData.ComplexGateway{activation_condition: "activatedCount >= 2"}
            }
          ],
          extra_flows: [
            %SequenceFlow{id: "F2", source_ref: "S1", target_ref: "T1"},
            %SequenceFlow{id: "F3", source_ref: "S1", target_ref: "T2"},
            %SequenceFlow{id: "Fa", source_ref: "T1", target_ref: "CGJoin"},
            %SequenceFlow{id: "Fb", source_ref: "T2", target_ref: "CGJoin"},
            %SequenceFlow{id: "Fc", source_ref: "CGJoin", target_ref: "E1"}
          ]
        )

      assert {:error, violations} = Validator.validate(definitions)

      {_, message} =
        Enum.find(violations, fn {c, _} -> c == :complex_join_no_paired_split end)

      assert message =~ "ComplexGateway 'CGJoin'"
      assert message =~ "no Complex Split dominates it"
    end

    test "rejects a region whose flow leaks out to an external node (single-exit violation)" do
      definitions =
        minimal_valid_definitions(
          extra_nodes: [
            %FlowNode{
              id: "CGSplit",
              type: :complex_gateway,
              type_data: %FlowNodeData.ComplexGateway{}
            },
            %FlowNode{id: "T1", type: :task, type_data: %FlowNodeData.Task{}},
            %FlowNode{id: "T2", type: :task, type_data: %FlowNodeData.Task{}},
            %FlowNode{
              id: "CGJoin",
              type: :complex_gateway,
              type_data: %FlowNodeData.ComplexGateway{activation_condition: "activatedCount >= 2"}
            }
          ],
          extra_flows: [
            %SequenceFlow{id: "Fin", source_ref: "S1", target_ref: "CGSplit"},
            %SequenceFlow{
              id: "Fa",
              source_ref: "CGSplit",
              target_ref: "T1",
              condition_expression: "token.a = true"
            },
            %SequenceFlow{id: "Fb", source_ref: "CGSplit", target_ref: "T2", is_default: true},
            %SequenceFlow{id: "Fc", source_ref: "T1", target_ref: "CGJoin"},
            %SequenceFlow{id: "Fd", source_ref: "T2", target_ref: "CGJoin"},
            %SequenceFlow{id: "Fe", source_ref: "CGJoin", target_ref: "E1"},
            %SequenceFlow{id: "Fleak", source_ref: "T1", target_ref: "E1"}
          ]
        )

      assert {:error, violations} = Validator.validate(definitions)

      {_, message} =
        Enum.find(violations, fn {c, _} -> c == :complex_region_cross_boundary end)

      assert message =~ "split 'CGSplit'"
      assert message =~ "join 'CGJoin'"
      assert message =~ "single-exit"
    end

    test "accepts a well-formed nested pair of complex regions" do
      definitions =
        minimal_valid_definitions(
          extra_nodes: [
            %FlowNode{
              id: "OuterSplit",
              type: :complex_gateway,
              type_data: %FlowNodeData.ComplexGateway{}
            },
            %FlowNode{
              id: "InnerSplit",
              type: :complex_gateway,
              type_data: %FlowNodeData.ComplexGateway{}
            },
            %FlowNode{id: "TaskA", type: :task, type_data: %FlowNodeData.Task{}},
            %FlowNode{id: "TaskB", type: :task, type_data: %FlowNodeData.Task{}},
            %FlowNode{id: "TaskC", type: :task, type_data: %FlowNodeData.Task{}},
            %FlowNode{
              id: "InnerJoin",
              type: :complex_gateway,
              type_data: %FlowNodeData.ComplexGateway{activation_condition: "activatedCount >= 1"}
            },
            %FlowNode{
              id: "OuterJoin",
              type: :complex_gateway,
              type_data: %FlowNodeData.ComplexGateway{activation_condition: "activatedCount >= 1"}
            }
          ],
          extra_flows: [
            %SequenceFlow{id: "Fin", source_ref: "S1", target_ref: "OuterSplit"},
            %SequenceFlow{
              id: "Fo1",
              source_ref: "OuterSplit",
              target_ref: "InnerSplit",
              condition_expression: "token.x = true"
            },
            %SequenceFlow{id: "Fo2", source_ref: "OuterSplit", target_ref: "TaskC", is_default: true},
            %SequenceFlow{
              id: "Fi1",
              source_ref: "InnerSplit",
              target_ref: "TaskA",
              condition_expression: "token.y = true"
            },
            %SequenceFlow{id: "Fi2", source_ref: "InnerSplit", target_ref: "TaskB", is_default: true},
            %SequenceFlow{id: "Fj1", source_ref: "TaskA", target_ref: "InnerJoin"},
            %SequenceFlow{id: "Fj2", source_ref: "TaskB", target_ref: "InnerJoin"},
            %SequenceFlow{id: "Fj3", source_ref: "InnerJoin", target_ref: "OuterJoin"},
            %SequenceFlow{id: "Fj4", source_ref: "TaskC", target_ref: "OuterJoin"},
            %SequenceFlow{id: "Fj5", source_ref: "OuterJoin", target_ref: "E1"}
          ]
        )

      refute_violation_code(definitions, :complex_join_no_paired_split)
      refute_violation_code(definitions, :complex_region_cross_boundary)
      refute_violation_code(definitions, :complex_region_overlap)
    end
  end

  # -------------------------------------------------------------------------
  # Event definition completeness
  # -------------------------------------------------------------------------

  describe "validate/1 — MessageEventDefinition completeness" do
    test "rejects message start event without messageRef" do
      definitions =
        minimal_valid_definitions(
          process: [
            flow_nodes: [
              %FlowNode{
                id: "S1",
                type: :start_event,
                type_data: %FlowNodeData.StartEvent{
                  event_definition: %EventDefinition.Message{}
                }
              },
              %FlowNode{id: "E1", type: :end_event, type_data: %FlowNodeData.EndEvent{}}
            ],
            sequence_flows: [%SequenceFlow{id: "F1", source_ref: "S1", target_ref: "E1"}]
          ]
        )

      assert {:error, violations} = Validator.validate(definitions)

      {_, message} = Enum.find(violations, fn {c, _} -> c == :incomplete_event_definition end)
      assert message =~ "StartEvent"
      assert message =~ "'S1'"
      assert message =~ "MessageEventDefinition"
      assert message =~ "messageRef"
    end

    test "rejects intermediate catch message event without messageRef" do
      definitions =
        minimal_valid_definitions(
          extra_nodes: [
            %FlowNode{
              id: "ICE1",
              type: :intermediate_catch_event,
              type_data: %FlowNodeData.IntermediateCatchEvent{
                event_definition: %EventDefinition.Message{}
              }
            }
          ],
          extra_flows: [
            %SequenceFlow{id: "F2", source_ref: "S1", target_ref: "ICE1"},
            %SequenceFlow{id: "F3", source_ref: "ICE1", target_ref: "E1"}
          ]
        )

      assert {:error, violations} = Validator.validate(definitions)
      assert Enum.any?(violations, fn {c, _} -> c == :incomplete_event_definition end)
    end
  end

  describe "validate/1 — SignalEventDefinition completeness" do
    test "rejects signal event without signalRef" do
      definitions =
        minimal_valid_definitions(
          extra_nodes: [
            %FlowNode{
              id: "ITE1",
              type: :intermediate_throw_event,
              type_data: %FlowNodeData.IntermediateThrowEvent{
                event_definition: %EventDefinition.Signal{}
              }
            }
          ],
          extra_flows: [
            %SequenceFlow{id: "F2", source_ref: "S1", target_ref: "ITE1"},
            %SequenceFlow{id: "F3", source_ref: "ITE1", target_ref: "E1"}
          ]
        )

      assert {:error, violations} = Validator.validate(definitions)

      {_, message} = Enum.find(violations, fn {c, _} -> c == :incomplete_event_definition end)
      assert message =~ "SignalEventDefinition"
      assert message =~ "signalRef"
    end
  end

  describe "validate/1 — TimerEventDefinition completeness" do
    test "rejects timer event with no time specification" do
      definitions =
        minimal_valid_definitions(
          process: [
            flow_nodes: [
              %FlowNode{
                id: "S1",
                type: :start_event,
                type_data: %FlowNodeData.StartEvent{
                  event_definition: %EventDefinition.Timer{}
                }
              },
              %FlowNode{id: "E1", type: :end_event, type_data: %FlowNodeData.EndEvent{}}
            ],
            sequence_flows: [%SequenceFlow{id: "F1", source_ref: "S1", target_ref: "E1"}]
          ]
        )

      assert {:error, violations} = Validator.validate(definitions)

      {_, message} = Enum.find(violations, fn {c, _} -> c == :incomplete_event_definition end)
      assert message =~ "TimerEventDefinition"
      assert message =~ "timeDate, timeDuration, or timeCycle"
    end

    test "passes when time_duration is set" do
      definitions =
        minimal_valid_definitions(
          process: [
            flow_nodes: [
              %FlowNode{
                id: "S1",
                type: :start_event,
                type_data: %FlowNodeData.StartEvent{
                  event_definition: %EventDefinition.Timer{time_duration: "PT30S"}
                }
              },
              %FlowNode{id: "E1", type: :end_event, type_data: %FlowNodeData.EndEvent{}}
            ],
            sequence_flows: [%SequenceFlow{id: "F1", source_ref: "S1", target_ref: "E1"}]
          ]
        )

      assert {:ok, _} = Validator.validate(definitions)
    end

    @tag :known_spec_gap
    test "passes when multiple timer fields are provided (validator only requires at least one)" do
      # BPMN spec: exactly one of timeDate, timeDuration, or timeCycle must be set.
      # Validator message claims "exactly one" but implementation only checks "at least one".
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
                        xmlns:evil="https://evilengine.dev/schema/bpmn"
                        id="Defs_1">
        <bpmn:process id="P1" name="Dual Timer Fields" isExecutable="true">
          <bpmn:extensionElements><evil:version>1.0.0</evil:version></bpmn:extensionElements>
          <bpmn:startEvent id="Start_1" name="Dual Timer">
            <bpmn:timerEventDefinition>
              <bpmn:timeDuration>PT30S</bpmn:timeDuration>
              <bpmn:timeDate>2026-06-17T10:00:00Z</bpmn:timeDate>
            </bpmn:timerEventDefinition>
            <bpmn:outgoing>F1</bpmn:outgoing>
          </bpmn:startEvent>
          <bpmn:endEvent id="End_1"><bpmn:incoming>F1</bpmn:incoming></bpmn:endEvent>
          <bpmn:sequenceFlow id="F1" sourceRef="Start_1" targetRef="End_1"/>
        </bpmn:process>
      </bpmn:definitions>
      """

      definitions = parse_fixture_from_xml(xml)
      assert {:ok, _} = Validator.validate(definitions)
    end
  end

  describe "validate/1 — ConditionalEventDefinition completeness" do
    test "rejects conditional event without condition expression" do
      definitions =
        minimal_valid_definitions(
          process: [
            flow_nodes: [
              %FlowNode{
                id: "S1",
                type: :start_event,
                type_data: %FlowNodeData.StartEvent{
                  event_definition: %EventDefinition.Conditional{}
                }
              },
              %FlowNode{id: "E1", type: :end_event, type_data: %FlowNodeData.EndEvent{}}
            ],
            sequence_flows: [%SequenceFlow{id: "F1", source_ref: "S1", target_ref: "E1"}]
          ]
        )

      assert {:error, violations} = Validator.validate(definitions)

      {_, message} = Enum.find(violations, fn {c, _} -> c == :incomplete_event_definition end)
      assert message =~ "ConditionalEventDefinition"
      assert message =~ "condition"
    end
  end

  describe "validate/1 — LinkEventDefinition completeness" do
    test "rejects link event without link name" do
      definitions =
        minimal_valid_definitions(
          extra_nodes: [
            %FlowNode{
              id: "ICE1",
              type: :intermediate_catch_event,
              type_data: %FlowNodeData.IntermediateCatchEvent{
                event_definition: %EventDefinition.Link{}
              }
            }
          ],
          extra_flows: [
            %SequenceFlow{id: "F2", source_ref: "S1", target_ref: "ICE1"},
            %SequenceFlow{id: "F3", source_ref: "ICE1", target_ref: "E1"}
          ]
        )

      assert {:error, violations} = Validator.validate(definitions)

      {_, message} = Enum.find(violations, fn {c, _} -> c == :incomplete_event_definition end)
      assert message =~ "LinkEventDefinition"
      assert message =~ "name"
    end
  end

  # -------------------------------------------------------------------------
  # Boundary event checks
  # -------------------------------------------------------------------------

  describe "validate/1 — BoundaryEvent completeness" do
    test "rejects boundary event without attachedToRef" do
      definitions =
        minimal_valid_definitions(
          extra_nodes: [
            %FlowNode{
              id: "BE1",
              type: :boundary_event,
              type_data: %FlowNodeData.BoundaryEvent{
                attached_to_ref: nil,
                event_definition: %EventDefinition.Timer{time_duration: "PT5M"}
              }
            }
          ]
        )

      assert {:error, violations} = Validator.validate(definitions)

      {_, message} = Enum.find(violations, fn {c, _} -> c == :incomplete_flow_node end)
      assert message =~ "BoundaryEvent"
      assert message =~ "'BE1'"
      assert message =~ "attachedToRef"
    end

    test "rejects boundary event with dangling attachedToRef" do
      definitions =
        minimal_valid_definitions(
          extra_nodes: [
            %FlowNode{
              id: "BE1",
              type: :boundary_event,
              type_data: %FlowNodeData.BoundaryEvent{
                attached_to_ref: "NonExistent_Task",
                event_definition: %EventDefinition.Timer{time_duration: "PT5M"}
              }
            }
          ]
        )

      assert {:error, violations} = Validator.validate(definitions)

      {_, message} =
        Enum.find(violations, fn {c, _} -> c == :boundary_event_dangling_attached_to end)

      assert message =~ "BoundaryEvent"
      assert message =~ "'BE1'"
      assert message =~ "NonExistent_Task"
    end

    test "boundary event also validates its event definition" do
      definitions =
        minimal_valid_definitions(
          extra_nodes: [
            %FlowNode{
              id: "UT1",
              type: :user_task,
              type_data: %FlowNodeData.UserTask{}
            },
            %FlowNode{
              id: "BE1",
              type: :boundary_event,
              type_data: %FlowNodeData.BoundaryEvent{
                attached_to_ref: "UT1",
                event_definition: %EventDefinition.Message{}
              }
            }
          ],
          extra_flows: [
            %SequenceFlow{id: "F2", source_ref: "S1", target_ref: "UT1"},
            %SequenceFlow{id: "F3", source_ref: "UT1", target_ref: "E1"}
          ]
        )

      assert {:error, violations} = Validator.validate(definitions)

      {_, message} = Enum.find(violations, fn {c, _} -> c == :incomplete_event_definition end)
      assert message =~ "BoundaryEvent"
      assert message =~ "MessageEventDefinition"
      assert message =~ "messageRef"
    end
  end

  # -------------------------------------------------------------------------
  # Data association reference checks
  # -------------------------------------------------------------------------

  describe "validate/1 — data association references" do
    test "dangling DOA target_ref produces error" do
      definitions =
        minimal_valid_definitions(
          process: [
            data_objects: [%EvilEngine.BPMN.Model.DataObject{id: "DO_1"}],
            data_object_references: [
              %EvilEngine.BPMN.Model.DataObjectReference{id: "DOR_1", data_object_ref: "DO_1"}
            ]
          ],
          extra_nodes: [
            %FlowNode{
              id: "ST1",
              type: :script_task,
              type_data: %FlowNodeData.ScriptTask{script: "1+1"},
              data_output_associations: [
                %EvilEngine.BPMN.Model.DataAssociation{id: "DOA_bad", target_ref: "NONEXISTENT"}
              ]
            }
          ],
          extra_flows: [
            %SequenceFlow{id: "F2", source_ref: "S1", target_ref: "ST1"},
            %SequenceFlow{id: "F3", source_ref: "ST1", target_ref: "E1"}
          ]
        )

      assert {:error, violations} = Validator.validate(definitions)
      codes = Enum.map(violations, fn {code, _} -> code end)
      assert :dangling_doa_target_ref in codes
    end

    test "dangling DIA source_ref produces error" do
      definitions =
        minimal_valid_definitions(
          process: [
            data_objects: [%EvilEngine.BPMN.Model.DataObject{id: "DO_1"}],
            data_object_references: [
              %EvilEngine.BPMN.Model.DataObjectReference{id: "DOR_1", data_object_ref: "DO_1"}
            ]
          ],
          extra_nodes: [
            %FlowNode{
              id: "ST1",
              type: :script_task,
              type_data: %FlowNodeData.ScriptTask{script: "1+1"},
              data_input_associations: [
                %EvilEngine.BPMN.Model.DataAssociation{id: "DIA_bad", source_ref: "NONEXISTENT"}
              ]
            }
          ],
          extra_flows: [
            %SequenceFlow{id: "F2", source_ref: "S1", target_ref: "ST1"},
            %SequenceFlow{id: "F3", source_ref: "ST1", target_ref: "E1"}
          ]
        )

      assert {:error, violations} = Validator.validate(definitions)
      codes = Enum.map(violations, fn {code, _} -> code end)
      assert :dangling_dia_source_ref in codes
    end

    test "valid associations pass validation" do
      definitions =
        minimal_valid_definitions(
          process: [
            data_objects: [%EvilEngine.BPMN.Model.DataObject{id: "DO_1"}],
            data_object_references: [
              %EvilEngine.BPMN.Model.DataObjectReference{id: "DOR_1", data_object_ref: "DO_1"}
            ]
          ],
          extra_nodes: [
            %FlowNode{
              id: "ST1",
              type: :script_task,
              type_data: %FlowNodeData.ScriptTask{script: "1+1"},
              data_output_associations: [
                %EvilEngine.BPMN.Model.DataAssociation{id: "DOA_1", target_ref: "DOR_1"}
              ],
              data_input_associations: [
                %EvilEngine.BPMN.Model.DataAssociation{id: "DIA_1", source_ref: "DOR_1"}
              ]
            }
          ],
          extra_flows: [
            %SequenceFlow{id: "F2", source_ref: "S1", target_ref: "ST1"},
            %SequenceFlow{id: "F3", source_ref: "ST1", target_ref: "E1"}
          ]
        )

      assert {:ok, _} = Validator.validate(definitions)
    end
  end

  # -------------------------------------------------------------------------
  # Value contract schema validation
  # -------------------------------------------------------------------------

  describe "validate/1 — value contract schemas" do
    test "invalid JSON Schema on DataObject produces error" do
      broken_schema = %{
        "type" => "object",
        "properties" => %{"x" => %{"$ref" => "#/definitions/nonexistent"}}
      }

      definitions =
        minimal_valid_definitions(
          process: [
            data_objects: [
              %EvilEngine.BPMN.Model.DataObject{id: "DO_1", value_contract: broken_schema}
            ],
            data_object_references: []
          ]
        )

      assert {:error, violations} = Validator.validate(definitions)
      codes = Enum.map(violations, fn {code, _} -> code end)
      assert :invalid_value_contract in codes
    end

    test "non-map value_contract produces error" do
      definitions =
        minimal_valid_definitions(
          process: [
            data_objects: [
              %EvilEngine.BPMN.Model.DataObject{id: "DO_1", value_contract: "not a map"}
            ],
            data_object_references: []
          ]
        )

      assert {:error, violations} = Validator.validate(definitions)
      codes = Enum.map(violations, fn {code, _} -> code end)
      assert :invalid_value_contract in codes
    end

    test "valid JSON Schema on DataObject passes" do
      definitions =
        minimal_valid_definitions(
          process: [
            data_objects: [
              %EvilEngine.BPMN.Model.DataObject{
                id: "DO_1",
                value_contract: %{"type" => "object", "required" => ["name"]}
              }
            ],
            data_object_references: []
          ]
        )

      assert {:ok, _} = Validator.validate(definitions)
    end

    test "nil value_contract passes without error" do
      definitions =
        minimal_valid_definitions(
          process: [
            data_objects: [
              %EvilEngine.BPMN.Model.DataObject{id: "DO_1", value_contract: nil}
            ],
            data_object_references: []
          ]
        )

      assert {:ok, _} = Validator.validate(definitions)
    end
  end

  # -------------------------------------------------------------------------
  # Embedded subprocess structural checks
  # -------------------------------------------------------------------------

  describe "validate/1 — embedded subprocess structural checks" do
    @valid_subprocess_xml """
    <?xml version="1.0" encoding="UTF-8"?>
    <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
                      xmlns:evil="https://evilengine.dev/schema/bpmn"
                      id="Definitions_1">
      <bpmn:process id="Process_1" name="With SubProcess" isExecutable="true">
        <bpmn:extensionElements>
          <evil:version>1.0.0</evil:version>
        </bpmn:extensionElements>
        <bpmn:startEvent id="Start_1">
          <bpmn:outgoing>Flow_1</bpmn:outgoing>
        </bpmn:startEvent>
        <bpmn:subProcess id="SubProcess_1" name="Embedded">
          <bpmn:startEvent id="Sub_Start_1">
            <bpmn:outgoing>Sub_Flow_1</bpmn:outgoing>
          </bpmn:startEvent>
          <bpmn:task id="Sub_Task_1" name="Inner Task">
            <bpmn:incoming>Sub_Flow_1</bpmn:incoming>
            <bpmn:outgoing>Sub_Flow_2</bpmn:outgoing>
          </bpmn:task>
          <bpmn:endEvent id="Sub_End_1">
            <bpmn:incoming>Sub_Flow_2</bpmn:incoming>
          </bpmn:endEvent>
          <bpmn:sequenceFlow id="Sub_Flow_1" sourceRef="Sub_Start_1" targetRef="Sub_Task_1" />
          <bpmn:sequenceFlow id="Sub_Flow_2" sourceRef="Sub_Task_1" targetRef="Sub_End_1" />
        </bpmn:subProcess>
        <bpmn:endEvent id="End_1">
          <bpmn:incoming>Flow_2</bpmn:incoming>
        </bpmn:endEvent>
        <bpmn:sequenceFlow id="Flow_1" sourceRef="Start_1" targetRef="SubProcess_1" />
        <bpmn:sequenceFlow id="Flow_2" sourceRef="SubProcess_1" targetRef="End_1" />
      </bpmn:process>
    </bpmn:definitions>
    """

    test "valid subprocess passes validation" do
      definitions = parse_fixture_from_xml(@valid_subprocess_xml)
      assert {:ok, ^definitions} = Validator.validate(definitions)
    end

    test "inner sequence flow with dangling sourceRef fails" do
      xml =
        String.replace(
          @valid_subprocess_xml,
          ~s(sourceRef="Sub_Start_1"),
          ~s(sourceRef="Missing_Source")
        )

      definitions = parse_fixture_from_xml(xml)
      assert {:error, violations} = Validator.validate(definitions)

      assert Enum.any?(violations, fn {code, message} ->
               code == :dangling_source_ref and message =~ "[in SubProcess 'SubProcess_1']"
             end)
    end

    test "inner sequence flow with dangling targetRef fails" do
      xml =
        String.replace(
          @valid_subprocess_xml,
          ~s(targetRef="Sub_Task_1"),
          ~s(targetRef="Missing_Target")
        )

      definitions = parse_fixture_from_xml(xml)
      assert {:error, violations} = Validator.validate(definitions)

      assert Enum.any?(violations, fn {code, message} ->
               code == :dangling_target_ref and message =~ "[in SubProcess 'SubProcess_1']"
             end)
    end

    test "inner orphan node fails" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
                        xmlns:evil="https://evilengine.dev/schema/bpmn"
                        id="Definitions_1">
        <bpmn:process id="Process_1" isExecutable="true">
          <bpmn:extensionElements>
            <evil:version>1.0.0</evil:version>
          </bpmn:extensionElements>
          <bpmn:startEvent id="Start_1">
            <bpmn:outgoing>Flow_1</bpmn:outgoing>
          </bpmn:startEvent>
          <bpmn:subProcess id="SubProcess_1">
            <bpmn:startEvent id="Sub_Start_1">
              <bpmn:outgoing>Sub_Flow_1</bpmn:outgoing>
            </bpmn:startEvent>
            <bpmn:task id="Orphan_Task_1" name="Unconnected" />
            <bpmn:endEvent id="Sub_End_1">
              <bpmn:incoming>Sub_Flow_1</bpmn:incoming>
            </bpmn:endEvent>
            <bpmn:sequenceFlow id="Sub_Flow_1" sourceRef="Sub_Start_1" targetRef="Sub_End_1" />
          </bpmn:subProcess>
          <bpmn:endEvent id="End_1">
            <bpmn:incoming>Flow_1</bpmn:incoming>
          </bpmn:endEvent>
          <bpmn:sequenceFlow id="Flow_1" sourceRef="Start_1" targetRef="End_1" />
        </bpmn:process>
      </bpmn:definitions>
      """

      definitions = parse_fixture_from_xml(xml)
      assert {:error, violations} = Validator.validate(definitions)

      assert Enum.any?(violations, fn {code, message} ->
               code == :orphan_node and message =~ "Orphan_Task_1" and
                 message =~ "[in SubProcess 'SubProcess_1']"
             end)
    end

    test "inner boundary event with dangling attachedToRef fails" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
                        xmlns:evil="https://evilengine.dev/schema/bpmn"
                        id="Definitions_1">
        <bpmn:process id="Process_1" isExecutable="true">
          <bpmn:extensionElements>
            <evil:version>1.0.0</evil:version>
          </bpmn:extensionElements>
          <bpmn:startEvent id="Start_1">
            <bpmn:outgoing>Flow_1</bpmn:outgoing>
          </bpmn:startEvent>
          <bpmn:subProcess id="SubProcess_1">
            <bpmn:startEvent id="Sub_Start_1">
              <bpmn:outgoing>Sub_Flow_1</bpmn:outgoing>
            </bpmn:startEvent>
            <bpmn:task id="Sub_Task_1">
              <bpmn:incoming>Sub_Flow_1</bpmn:incoming>
              <bpmn:outgoing>Sub_Flow_2</bpmn:outgoing>
            </bpmn:task>
            <bpmn:boundaryEvent id="Boundary_1" attachedToRef="Parent_Task_1">
              <bpmn:outgoing>Sub_Flow_3</bpmn:outgoing>
            </bpmn:boundaryEvent>
            <bpmn:endEvent id="Sub_End_1">
              <bpmn:incoming>Sub_Flow_2</bpmn:incoming>
            </bpmn:endEvent>
            <bpmn:sequenceFlow id="Sub_Flow_1" sourceRef="Sub_Start_1" targetRef="Sub_Task_1" />
            <bpmn:sequenceFlow id="Sub_Flow_2" sourceRef="Sub_Task_1" targetRef="Sub_End_1" />
            <bpmn:sequenceFlow id="Sub_Flow_3" sourceRef="Boundary_1" targetRef="Sub_End_1" />
          </bpmn:subProcess>
          <bpmn:endEvent id="End_1">
            <bpmn:incoming>Flow_1</bpmn:incoming>
          </bpmn:endEvent>
          <bpmn:sequenceFlow id="Flow_1" sourceRef="Start_1" targetRef="End_1" />
        </bpmn:process>
      </bpmn:definitions>
      """

      definitions = parse_fixture_from_xml(xml)
      assert {:error, violations} = Validator.validate(definitions)

      assert Enum.any?(violations, fn {code, message} ->
               code == :boundary_event_dangling_attached_to and
                 message =~ "Parent_Task_1" and message =~ "[in SubProcess 'SubProcess_1']"
             end)
    end

    test "inner flow node missing required properties fails" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
                        xmlns:evil="https://evilengine.dev/schema/bpmn"
                        id="Definitions_1">
        <bpmn:process id="Process_1" isExecutable="true">
          <bpmn:extensionElements>
            <evil:version>1.0.0</evil:version>
          </bpmn:extensionElements>
          <bpmn:startEvent id="Start_1">
            <bpmn:outgoing>Flow_1</bpmn:outgoing>
          </bpmn:startEvent>
          <bpmn:subProcess id="SubProcess_1">
            <bpmn:startEvent id="Sub_Start_1">
              <bpmn:outgoing>Sub_Flow_1</bpmn:outgoing>
            </bpmn:startEvent>
            <bpmn:serviceTask id="Sub_Service_1" name="Missing Implementation">
              <bpmn:incoming>Sub_Flow_1</bpmn:incoming>
              <bpmn:outgoing>Sub_Flow_2</bpmn:outgoing>
            </bpmn:serviceTask>
            <bpmn:endEvent id="Sub_End_1">
              <bpmn:incoming>Sub_Flow_2</bpmn:incoming>
            </bpmn:endEvent>
            <bpmn:sequenceFlow id="Sub_Flow_1" sourceRef="Sub_Start_1" targetRef="Sub_Service_1" />
            <bpmn:sequenceFlow id="Sub_Flow_2" sourceRef="Sub_Service_1" targetRef="Sub_End_1" />
          </bpmn:subProcess>
          <bpmn:endEvent id="End_1">
            <bpmn:incoming>Flow_1</bpmn:incoming>
          </bpmn:endEvent>
          <bpmn:sequenceFlow id="Flow_1" sourceRef="Start_1" targetRef="End_1" />
        </bpmn:process>
      </bpmn:definitions>
      """

      definitions = parse_fixture_from_xml(xml)
      assert {:error, violations} = Validator.validate(definitions)

      assert Enum.any?(violations, fn {code, message} ->
               code == :incomplete_flow_node and message =~ "Sub_Service_1" and
                 message =~ "implementation" and message =~ "[in SubProcess 'SubProcess_1']"
             end)
    end

    test "nested subprocess validation is recursive" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
                        xmlns:evil="https://evilengine.dev/schema/bpmn"
                        id="Definitions_1">
        <bpmn:process id="Process_1" isExecutable="true">
          <bpmn:extensionElements>
            <evil:version>1.0.0</evil:version>
          </bpmn:extensionElements>
          <bpmn:startEvent id="Start_1">
            <bpmn:outgoing>Flow_1</bpmn:outgoing>
          </bpmn:startEvent>
          <bpmn:subProcess id="SubProcess_Outer">
            <bpmn:startEvent id="Outer_Start_1">
              <bpmn:outgoing>Outer_Flow_1</bpmn:outgoing>
            </bpmn:startEvent>
            <bpmn:subProcess id="SubProcess_Inner">
              <bpmn:task id="Inner_Orphan_1" name="Unconnected" />
            </bpmn:subProcess>
            <bpmn:endEvent id="Outer_End_1">
              <bpmn:incoming>Outer_Flow_1</bpmn:incoming>
            </bpmn:endEvent>
            <bpmn:sequenceFlow id="Outer_Flow_1" sourceRef="Outer_Start_1" targetRef="Outer_End_1" />
          </bpmn:subProcess>
          <bpmn:endEvent id="End_1">
            <bpmn:incoming>Flow_1</bpmn:incoming>
          </bpmn:endEvent>
          <bpmn:sequenceFlow id="Flow_1" sourceRef="Start_1" targetRef="End_1" />
        </bpmn:process>
      </bpmn:definitions>
      """

      definitions = parse_fixture_from_xml(xml)
      assert {:error, violations} = Validator.validate(definitions)

      assert Enum.any?(violations, fn {code, message} ->
               code == :orphan_node and message =~ "Inner_Orphan_1" and
                 message =~ "[in SubProcess 'SubProcess_Inner']"
             end)
    end

    test "cross-boundary sequence flow fails" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
                        xmlns:evil="https://evilengine.dev/schema/bpmn"
                        id="Definitions_1">
        <bpmn:process id="Process_1" isExecutable="true">
          <bpmn:extensionElements>
            <evil:version>1.0.0</evil:version>
          </bpmn:extensionElements>
          <bpmn:startEvent id="Start_1">
            <bpmn:outgoing>Flow_1</bpmn:outgoing>
          </bpmn:startEvent>
          <bpmn:subProcess id="SubProcess_1">
            <bpmn:startEvent id="Sub_Start_1">
              <bpmn:outgoing>Sub_Flow_1</bpmn:outgoing>
            </bpmn:startEvent>
            <bpmn:task id="Sub_Task_1">
              <bpmn:incoming>Sub_Flow_1</bpmn:incoming>
              <bpmn:outgoing>Sub_Flow_2</bpmn:outgoing>
            </bpmn:task>
            <bpmn:endEvent id="Sub_End_1">
              <bpmn:incoming>Sub_Flow_2</bpmn:incoming>
            </bpmn:endEvent>
            <bpmn:sequenceFlow id="Sub_Flow_1" sourceRef="Sub_Start_1" targetRef="Sub_Task_1" />
            <bpmn:sequenceFlow id="Sub_Flow_2" sourceRef="Sub_Task_1" targetRef="Sub_End_1" />
          </bpmn:subProcess>
          <bpmn:endEvent id="End_1">
            <bpmn:incoming>Flow_2</bpmn:incoming>
          </bpmn:endEvent>
          <bpmn:sequenceFlow id="Flow_1" sourceRef="Start_1" targetRef="Sub_Task_1" />
          <bpmn:sequenceFlow id="Flow_2" sourceRef="SubProcess_1" targetRef="End_1" />
        </bpmn:process>
      </bpmn:definitions>
      """

      definitions = parse_fixture_from_xml(xml)
      assert {:error, violations} = Validator.validate(definitions)

      assert Enum.any?(violations, fn {code, message} ->
               code == :cross_boundary_flow and message =~ "Sub_Task_1" and
                 message =~ "parent scope"
             end)
    end

    test "event subprocess inner scope IS validated (orphan node rejected)" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
                        xmlns:evil="https://evilengine.dev/schema/bpmn"
                        id="Definitions_1">
        <bpmn:process id="Process_1" isExecutable="true">
          <bpmn:extensionElements>
            <evil:version>1.0.0</evil:version>
          </bpmn:extensionElements>
          <bpmn:startEvent id="Start_1">
            <bpmn:outgoing>Flow_1</bpmn:outgoing>
          </bpmn:startEvent>
          <bpmn:subProcess id="EventSub_1" triggeredByEvent="true">
            <bpmn:startEvent id="EventSub_Start_1">
              <bpmn:messageEventDefinition id="EventSub_MsgDef_1" messageRef="Msg_1" />
              <bpmn:outgoing>EventSub_Flow_1</bpmn:outgoing>
            </bpmn:startEvent>
            <bpmn:endEvent id="EventSub_End_1">
              <bpmn:incoming>EventSub_Flow_1</bpmn:incoming>
            </bpmn:endEvent>
            <bpmn:task id="EventSub_Orphan_1" name="Orphan task now validated" />
            <bpmn:sequenceFlow id="EventSub_Flow_1" sourceRef="EventSub_Start_1" targetRef="EventSub_End_1" />
          </bpmn:subProcess>
          <bpmn:endEvent id="End_1">
            <bpmn:incoming>Flow_1</bpmn:incoming>
          </bpmn:endEvent>
          <bpmn:sequenceFlow id="Flow_1" sourceRef="Start_1" targetRef="End_1" />
        </bpmn:process>
      </bpmn:definitions>
      """

      definitions = parse_fixture_from_xml(xml)
      assert {:error, violations} = Validator.validate(definitions)

      assert Enum.any?(violations, fn {code, message} ->
               code == :orphan_node and message =~ "EventSub_Orphan_1" and
                 message =~ "Event SubProcess"
             end)
    end
  end

  # -------------------------------------------------------------------------
  # Event Subprocess structural validation (ESP-D7)
  # -------------------------------------------------------------------------

  describe "validate/1 — Event Subprocess structure" do
    test "valid message-triggered ESP passes" do
      esp = """
      <bpmn:subProcess id="ESP_Msg" triggeredByEvent="true">
        <bpmn:startEvent id="ESP_Msg_Start">
          <bpmn:messageEventDefinition id="ESP_Msg_Def" messageRef="Msg_ESP" />
          <bpmn:outgoing>ESP_Msg_SF</bpmn:outgoing>
        </bpmn:startEvent>
        <bpmn:endEvent id="ESP_Msg_End">
          <bpmn:incoming>ESP_Msg_SF</bpmn:incoming>
        </bpmn:endEvent>
        <bpmn:sequenceFlow id="ESP_Msg_SF" sourceRef="ESP_Msg_Start" targetRef="ESP_Msg_End" />
      </bpmn:subProcess>
      """

      assert {:ok, _} = validate_esp(esp, ~s(<bpmn:message id="Msg_ESP" name="esp-msg" />))
    end

    test "valid signal-triggered ESP passes" do
      esp = """
      <bpmn:subProcess id="ESP_Sig" triggeredByEvent="true">
        <bpmn:startEvent id="ESP_Sig_Start">
          <bpmn:signalEventDefinition id="ESP_Sig_Def" signalRef="Sig_ESP" />
          <bpmn:outgoing>ESP_Sig_SF</bpmn:outgoing>
        </bpmn:startEvent>
        <bpmn:endEvent id="ESP_Sig_End">
          <bpmn:incoming>ESP_Sig_SF</bpmn:incoming>
        </bpmn:endEvent>
        <bpmn:sequenceFlow id="ESP_Sig_SF" sourceRef="ESP_Sig_Start" targetRef="ESP_Sig_End" />
      </bpmn:subProcess>
      """

      assert {:ok, _} = validate_esp(esp, ~s(<bpmn:signal id="Sig_ESP" name="esp-sig" />))
    end

    test "valid timer-triggered ESP passes" do
      esp = """
      <bpmn:subProcess id="ESP_Timer" triggeredByEvent="true">
        <bpmn:startEvent id="ESP_Timer_Start">
          <bpmn:timerEventDefinition id="ESP_Timer_Def">
            <bpmn:timeDuration>PT5M</bpmn:timeDuration>
          </bpmn:timerEventDefinition>
          <bpmn:outgoing>ESP_Timer_SF</bpmn:outgoing>
        </bpmn:startEvent>
        <bpmn:endEvent id="ESP_Timer_End">
          <bpmn:incoming>ESP_Timer_SF</bpmn:incoming>
        </bpmn:endEvent>
        <bpmn:sequenceFlow id="ESP_Timer_SF" sourceRef="ESP_Timer_Start" targetRef="ESP_Timer_End" />
      </bpmn:subProcess>
      """

      assert {:ok, _} = validate_esp(esp)
    end

    test "valid interrupting error-triggered ESP passes" do
      esp = """
      <bpmn:subProcess id="ESP_Err" triggeredByEvent="true">
        <bpmn:startEvent id="ESP_Err_Start" isInterrupting="true">
          <bpmn:errorEventDefinition id="ESP_Err_Def" errorRef="Err_ESP" />
          <bpmn:outgoing>ESP_Err_SF</bpmn:outgoing>
        </bpmn:startEvent>
        <bpmn:endEvent id="ESP_Err_End">
          <bpmn:incoming>ESP_Err_SF</bpmn:incoming>
        </bpmn:endEvent>
        <bpmn:sequenceFlow id="ESP_Err_SF" sourceRef="ESP_Err_Start" targetRef="ESP_Err_End" />
      </bpmn:subProcess>
      """

      assert {:ok, _} = validate_esp(esp, ~s(<bpmn:error id="Err_ESP" name="err" errorCode="E1" />))
    end

    test "valid escalation-triggered ESP passes" do
      esp = """
      <bpmn:subProcess id="ESP_Esc" triggeredByEvent="true">
        <bpmn:startEvent id="ESP_Esc_Start">
          <bpmn:escalationEventDefinition id="ESP_Esc_Def" escalationRef="Esc_ESP" />
          <bpmn:outgoing>ESP_Esc_SF</bpmn:outgoing>
        </bpmn:startEvent>
        <bpmn:endEvent id="ESP_Esc_End">
          <bpmn:incoming>ESP_Esc_SF</bpmn:incoming>
        </bpmn:endEvent>
        <bpmn:sequenceFlow id="ESP_Esc_SF" sourceRef="ESP_Esc_Start" targetRef="ESP_Esc_End" />
      </bpmn:subProcess>
      """

      assert {:ok, _} =
               validate_esp(esp, ~s(<bpmn:escalation id="Esc_ESP" name="esc" escalationCode="ES1" />))
    end

    test "valid conditional-triggered ESP passes" do
      esp = """
      <bpmn:subProcess id="ESP_Cond" triggeredByEvent="true">
        <bpmn:startEvent id="ESP_Cond_Start">
          <bpmn:conditionalEventDefinition id="ESP_Cond_Def">
            <bpmn:condition>token.ready = true</bpmn:condition>
          </bpmn:conditionalEventDefinition>
          <bpmn:outgoing>ESP_Cond_SF</bpmn:outgoing>
        </bpmn:startEvent>
        <bpmn:endEvent id="ESP_Cond_End">
          <bpmn:incoming>ESP_Cond_SF</bpmn:incoming>
        </bpmn:endEvent>
        <bpmn:sequenceFlow id="ESP_Cond_SF" sourceRef="ESP_Cond_Start" targetRef="ESP_Cond_End" />
      </bpmn:subProcess>
      """

      assert {:ok, _} = validate_esp(esp)
    end

    test "valid compensation-triggered ESP passes" do
      esp = """
      <bpmn:subProcess id="ESP_Comp" triggeredByEvent="true">
        <bpmn:startEvent id="ESP_Comp_Start">
          <bpmn:compensateEventDefinition id="ESP_Comp_Def" />
          <bpmn:outgoing>ESP_Comp_SF</bpmn:outgoing>
        </bpmn:startEvent>
        <bpmn:endEvent id="ESP_Comp_End">
          <bpmn:incoming>ESP_Comp_SF</bpmn:incoming>
        </bpmn:endEvent>
        <bpmn:sequenceFlow id="ESP_Comp_SF" sourceRef="ESP_Comp_Start" targetRef="ESP_Comp_End" />
      </bpmn:subProcess>
      """

      assert {:ok, _} = validate_esp(esp)
    end

    test "ESP with no start event is rejected" do
      esp = """
      <bpmn:subProcess id="ESP_NoStart" triggeredByEvent="true">
        <bpmn:endEvent id="ESP_NoStart_End" />
      </bpmn:subProcess>
      """

      assert {:error, violations} = validate_esp(esp)
      assert Enum.any?(violations, fn {code, _} -> code == :event_subprocess_no_start_event end)
    end

    test "ESP with multiple start events is rejected" do
      esp = """
      <bpmn:subProcess id="ESP_MultiStart" triggeredByEvent="true">
        <bpmn:startEvent id="ESP_MS_1">
          <bpmn:messageEventDefinition id="ESP_MS_Def1" messageRef="Msg_ESP" />
          <bpmn:outgoing>ESP_MS_SF</bpmn:outgoing>
        </bpmn:startEvent>
        <bpmn:startEvent id="ESP_MS_2">
          <bpmn:signalEventDefinition id="ESP_MS_Def2" signalRef="Sig_ESP" />
        </bpmn:startEvent>
        <bpmn:endEvent id="ESP_MS_End">
          <bpmn:incoming>ESP_MS_SF</bpmn:incoming>
        </bpmn:endEvent>
        <bpmn:sequenceFlow id="ESP_MS_SF" sourceRef="ESP_MS_1" targetRef="ESP_MS_End" />
      </bpmn:subProcess>
      """

      globals =
        ~s(<bpmn:message id="Msg_ESP" name="m" /><bpmn:signal id="Sig_ESP" name="s" />)

      assert {:error, violations} = validate_esp(esp, globals)

      assert Enum.any?(violations, fn {code, _} ->
               code == :event_subprocess_multiple_start_events
             end)
    end

    test "ESP with an untyped (none) start event is rejected" do
      esp = """
      <bpmn:subProcess id="ESP_None" triggeredByEvent="true">
        <bpmn:startEvent id="ESP_None_Start">
          <bpmn:outgoing>ESP_None_SF</bpmn:outgoing>
        </bpmn:startEvent>
        <bpmn:endEvent id="ESP_None_End">
          <bpmn:incoming>ESP_None_SF</bpmn:incoming>
        </bpmn:endEvent>
        <bpmn:sequenceFlow id="ESP_None_SF" sourceRef="ESP_None_Start" targetRef="ESP_None_End" />
      </bpmn:subProcess>
      """

      assert {:error, violations} = validate_esp(esp)
      assert Enum.any?(violations, fn {code, _} -> code == :event_subprocess_untyped_start end)
    end

    test "ESP with a non-interrupting error start is rejected" do
      esp = """
      <bpmn:subProcess id="ESP_ErrNI" triggeredByEvent="true">
        <bpmn:startEvent id="ESP_ErrNI_Start" isInterrupting="false">
          <bpmn:errorEventDefinition id="ESP_ErrNI_Def" errorRef="Err_ESP" />
          <bpmn:outgoing>ESP_ErrNI_SF</bpmn:outgoing>
        </bpmn:startEvent>
        <bpmn:endEvent id="ESP_ErrNI_End">
          <bpmn:incoming>ESP_ErrNI_SF</bpmn:incoming>
        </bpmn:endEvent>
        <bpmn:sequenceFlow id="ESP_ErrNI_SF" sourceRef="ESP_ErrNI_Start" targetRef="ESP_ErrNI_End" />
      </bpmn:subProcess>
      """

      assert {:error, violations} =
               validate_esp(esp, ~s(<bpmn:error id="Err_ESP" name="err" errorCode="E1" />))

      assert Enum.any?(violations, fn {code, _} ->
               code == :event_subprocess_error_start_must_interrupt
             end)
    end

    test "ESP shell with an incoming sequence flow is rejected" do
      esp = """
      <bpmn:subProcess id="ESP_WithFlow" triggeredByEvent="true">
        <bpmn:incoming>Bad_Flow</bpmn:incoming>
        <bpmn:startEvent id="ESP_WF_Start">
          <bpmn:messageEventDefinition id="ESP_WF_Def" messageRef="Msg_ESP" />
          <bpmn:outgoing>ESP_WF_SF</bpmn:outgoing>
        </bpmn:startEvent>
        <bpmn:endEvent id="ESP_WF_End">
          <bpmn:incoming>ESP_WF_SF</bpmn:incoming>
        </bpmn:endEvent>
        <bpmn:sequenceFlow id="ESP_WF_SF" sourceRef="ESP_WF_Start" targetRef="ESP_WF_End" />
      </bpmn:subProcess>
      <bpmn:sequenceFlow id="Bad_Flow" sourceRef="Main_Start" targetRef="ESP_WithFlow" />
      """

      assert {:error, violations} =
               validate_esp(esp, ~s(<bpmn:message id="Msg_ESP" name="m" />))

      assert Enum.any?(violations, fn {code, _} ->
               code == :event_subprocess_has_sequence_flow
             end)
    end

    test "nested ESP inner scope is validated (orphan inside inner ESP rejected)" do
      esp = """
      <bpmn:subProcess id="ESP_Outer" triggeredByEvent="true">
        <bpmn:startEvent id="ESP_Outer_Start">
          <bpmn:messageEventDefinition id="ESP_Outer_Def" messageRef="Msg_ESP" />
          <bpmn:outgoing>ESP_Outer_SF</bpmn:outgoing>
        </bpmn:startEvent>
        <bpmn:endEvent id="ESP_Outer_End">
          <bpmn:incoming>ESP_Outer_SF</bpmn:incoming>
        </bpmn:endEvent>
        <bpmn:sequenceFlow id="ESP_Outer_SF" sourceRef="ESP_Outer_Start" targetRef="ESP_Outer_End" />
        <bpmn:subProcess id="ESP_Inner" triggeredByEvent="true">
          <bpmn:startEvent id="ESP_Inner_Start">
            <bpmn:signalEventDefinition id="ESP_Inner_Def" signalRef="Sig_ESP" />
            <bpmn:outgoing>ESP_Inner_SF</bpmn:outgoing>
          </bpmn:startEvent>
          <bpmn:endEvent id="ESP_Inner_End">
            <bpmn:incoming>ESP_Inner_SF</bpmn:incoming>
          </bpmn:endEvent>
          <bpmn:task id="ESP_Inner_Orphan" name="Nested orphan" />
          <bpmn:sequenceFlow id="ESP_Inner_SF" sourceRef="ESP_Inner_Start" targetRef="ESP_Inner_End" />
        </bpmn:subProcess>
      </bpmn:subProcess>
      """

      globals =
        ~s(<bpmn:message id="Msg_ESP" name="m" /><bpmn:signal id="Sig_ESP" name="s" />)

      assert {:error, violations} = validate_esp(esp, globals)

      assert Enum.any?(violations, fn {code, message} ->
               code == :orphan_node and message =~ "ESP_Inner_Orphan"
             end)
    end
  end

  # -------------------------------------------------------------------------
  # Collective error collection
  # -------------------------------------------------------------------------

  describe "validate/1 — collects all violations" do
    test "returns all issues at once, not just the first one" do
      definitions = %Definitions{
        raw_xml: "",
        processes: [
          %BpmnProcess{
            id: "P1",
            version: nil,
            flow_nodes: [
              %FlowNode{
                id: "CA1",
                type: :call_activity,
                type_data: %FlowNodeData.CallActivity{}
              }
            ]
          }
        ]
      }

      assert {:error, violations} = Validator.validate(definitions)

      codes = Enum.map(violations, fn {code, _} -> code end)
      assert :missing_version in codes
      assert :missing_start_event in codes
      assert :missing_end_event in codes
      assert :incomplete_flow_node in codes
      assert length(violations) >= 4
    end
  end

  # -------------------------------------------------------------------------
  # Round-trip integration
  # -------------------------------------------------------------------------

  describe "parse_and_validate/1 — round-trip" do
    test "valid BPMN passes both parse and validate" do
      xml = File.read!(Path.join(@fixtures_dir, "minimal_valid.bpmn"))
      assert {:ok, %Definitions{}} = EvilEngine.BPMN.parse_and_validate(xml)
    end

    test "invalid BPMN is rejected with violations list" do
      xml = File.read!(Path.join(@fixtures_dir, "missing_version.bpmn"))
      assert {:error, violations} = EvilEngine.BPMN.parse_and_validate(xml)
      assert is_list(violations)
      assert [_ | _] = violations
    end

    test "malformed XML is rejected at parse stage" do
      assert {:error, reason} = EvilEngine.BPMN.parse_and_validate("<<< garbage >>>")
      assert reason != nil
    end
  end

  # -------------------------------------------------------------------------
  # Event-Based Gateway validation
  # -------------------------------------------------------------------------

  describe "validate/1 — EventBasedGateway rules" do
    defp ebg_definitions(flow_nodes, sequence_flows, opts) do
      messages = Keyword.get(opts, :messages, [])

      process = %BpmnProcess{
        id: "P1",
        version: "1.0",
        is_executable: true,
        flow_nodes: flow_nodes,
        sequence_flows: sequence_flows
      }

      %Definitions{raw_xml: "", processes: [process], messages: messages}
    end

    test "valid EBG with timer catch + message catch passes" do
      definitions =
        ebg_definitions(
          [
            %FlowNode{id: "S1", type: :start_event, type_data: %FlowNodeData.StartEvent{}, outgoing: ["F1"]},
            %FlowNode{
              id: "EBG_1",
              type: :event_based_gateway,
              type_data: %FlowNodeData.EventBasedGateway{},
              incoming: ["F1"],
              outgoing: ["F_Timer", "F_Message"]
            },
            %FlowNode{
              id: "TC_1",
              type: :intermediate_catch_event,
              type_data: %FlowNodeData.IntermediateCatchEvent{
                event_definition: %EventDefinition.Timer{time_duration: "PT10S"}
              },
              incoming: ["F_Timer"],
              outgoing: ["F_TC_End"]
            },
            %FlowNode{
              id: "MC_1",
              type: :intermediate_catch_event,
              type_data: %FlowNodeData.IntermediateCatchEvent{
                event_definition: %EventDefinition.Message{message_ref: "Msg_1"}
              },
              incoming: ["F_Message"],
              outgoing: ["F_MC_End"]
            },
            %FlowNode{id: "E1", type: :end_event, type_data: %FlowNodeData.EndEvent{}, incoming: ["F_TC_End", "F_MC_End"]}
          ],
          [
            %SequenceFlow{id: "F1", source_ref: "S1", target_ref: "EBG_1"},
            %SequenceFlow{id: "F_Timer", source_ref: "EBG_1", target_ref: "TC_1"},
            %SequenceFlow{id: "F_Message", source_ref: "EBG_1", target_ref: "MC_1"},
            %SequenceFlow{id: "F_TC_End", source_ref: "TC_1", target_ref: "E1"},
            %SequenceFlow{id: "F_MC_End", source_ref: "MC_1", target_ref: "E1"}
          ],
          messages: [%MessageDefinition{id: "Msg_1", name: "test-msg"}]
        )

      assert {:ok, _} = Validator.validate(definitions)
    end

    test "valid EBG with Receive Task (no boundary) passes" do
      definitions =
        ebg_definitions(
          [
            %FlowNode{id: "S1", type: :start_event, type_data: %FlowNodeData.StartEvent{}, outgoing: ["F1"]},
            %FlowNode{
              id: "EBG_1",
              type: :event_based_gateway,
              type_data: %FlowNodeData.EventBasedGateway{},
              incoming: ["F1"],
              outgoing: ["F_Recv", "F_Timer"]
            },
            %FlowNode{
              id: "RT_1",
              type: :receive_task,
              type_data: %FlowNodeData.ReceiveTask{message_ref: "Msg_1"},
              incoming: ["F_Recv"],
              outgoing: ["F_RT_End"]
            },
            %FlowNode{
              id: "TC_1",
              type: :intermediate_catch_event,
              type_data: %FlowNodeData.IntermediateCatchEvent{
                event_definition: %EventDefinition.Timer{time_duration: "PT10S"}
              },
              incoming: ["F_Timer"],
              outgoing: ["F_TC_End"]
            },
            %FlowNode{id: "E1", type: :end_event, type_data: %FlowNodeData.EndEvent{}, incoming: ["F_RT_End", "F_TC_End"]}
          ],
          [
            %SequenceFlow{id: "F1", source_ref: "S1", target_ref: "EBG_1"},
            %SequenceFlow{id: "F_Recv", source_ref: "EBG_1", target_ref: "RT_1"},
            %SequenceFlow{id: "F_Timer", source_ref: "EBG_1", target_ref: "TC_1"},
            %SequenceFlow{id: "F_RT_End", source_ref: "RT_1", target_ref: "E1"},
            %SequenceFlow{id: "F_TC_End", source_ref: "TC_1", target_ref: "E1"}
          ],
          messages: [%MessageDefinition{id: "Msg_1", name: "test-msg"}]
        )

      assert {:ok, _} = Validator.validate(definitions)
    end

    test "rejects a Script Task successor of an Event-Based Gateway" do
      definitions =
        ebg_definitions(
          [
            %FlowNode{id: "S1", type: :start_event, type_data: %FlowNodeData.StartEvent{}, outgoing: ["F1"]},
            %FlowNode{
              id: "EBG_1",
              type: :event_based_gateway,
              type_data: %FlowNodeData.EventBasedGateway{},
              incoming: ["F1"],
              outgoing: ["F_Script", "F_Timer"]
            },
            %FlowNode{
              id: "ST_1",
              type: :script_task,
              type_data: %FlowNodeData.ScriptTask{script: "1"},
              incoming: ["F_Script"],
              outgoing: ["F_ST_End"]
            },
            %FlowNode{
              id: "TC_1",
              type: :intermediate_catch_event,
              type_data: %FlowNodeData.IntermediateCatchEvent{
                event_definition: %EventDefinition.Timer{time_duration: "PT10S"}
              },
              incoming: ["F_Timer"],
              outgoing: ["F_TC_End"]
            },
            %FlowNode{id: "E1", type: :end_event, type_data: %FlowNodeData.EndEvent{}, incoming: ["F_ST_End", "F_TC_End"]}
          ],
          [
            %SequenceFlow{id: "F1", source_ref: "S1", target_ref: "EBG_1"},
            %SequenceFlow{id: "F_Script", source_ref: "EBG_1", target_ref: "ST_1"},
            %SequenceFlow{id: "F_Timer", source_ref: "EBG_1", target_ref: "TC_1"},
            %SequenceFlow{id: "F_ST_End", source_ref: "ST_1", target_ref: "E1"},
            %SequenceFlow{id: "F_TC_End", source_ref: "TC_1", target_ref: "E1"}
          ],
          []
        )

      assert {:error, violations} = Validator.validate(definitions)

      {_, message} =
        Enum.find(violations, fn {code, _} -> code == :event_based_gateway_invalid_successor end)

      assert message =~ "EventBasedGateway 'EBG_1'"
      assert message =~ "ST_1"
    end

    test "V-EBG-1: rejects Receive Task with boundary event after EBG" do
      definitions =
        ebg_definitions(
          [
            %FlowNode{id: "S1", type: :start_event, type_data: %FlowNodeData.StartEvent{}, outgoing: ["F1"]},
            %FlowNode{
              id: "EBG_1",
              type: :event_based_gateway,
              type_data: %FlowNodeData.EventBasedGateway{},
              incoming: ["F1"],
              outgoing: ["F_Recv", "F_Timer"]
            },
            %FlowNode{
              id: "RT_1",
              type: :receive_task,
              type_data: %FlowNodeData.ReceiveTask{message_ref: "Msg_1"},
              incoming: ["F_Recv"],
              outgoing: ["F_RT_End"],
              boundary_event_refs: ["BE_Timer"]
            },
            %FlowNode{
              id: "BE_Timer",
              type: :boundary_event,
              type_data: %FlowNodeData.BoundaryEvent{
                attached_to_ref: "RT_1",
                cancel_activity: true,
                event_definition: %EventDefinition.Timer{time_duration: "PT30S"}
              },
              outgoing: ["F_BE_End"]
            },
            %FlowNode{
              id: "TC_1",
              type: :intermediate_catch_event,
              type_data: %FlowNodeData.IntermediateCatchEvent{
                event_definition: %EventDefinition.Timer{time_duration: "PT10S"}
              },
              incoming: ["F_Timer"],
              outgoing: ["F_TC_End"]
            },
            %FlowNode{id: "E1", type: :end_event, type_data: %FlowNodeData.EndEvent{}, incoming: ["F_RT_End", "F_TC_End", "F_BE_End"]}
          ],
          [
            %SequenceFlow{id: "F1", source_ref: "S1", target_ref: "EBG_1"},
            %SequenceFlow{id: "F_Recv", source_ref: "EBG_1", target_ref: "RT_1"},
            %SequenceFlow{id: "F_Timer", source_ref: "EBG_1", target_ref: "TC_1"},
            %SequenceFlow{id: "F_RT_End", source_ref: "RT_1", target_ref: "E1"},
            %SequenceFlow{id: "F_TC_End", source_ref: "TC_1", target_ref: "E1"},
            %SequenceFlow{id: "F_BE_End", source_ref: "BE_Timer", target_ref: "E1"}
          ],
          messages: [%MessageDefinition{id: "Msg_1", name: "test-msg"}]
        )

      assert {:error, violations} = Validator.validate(definitions)

      assert Enum.any?(violations, fn {code, _message} ->
               code == :event_based_gateway_receive_task_has_boundary
             end)

      {_, message} =
        Enum.find(violations, fn {code, _} ->
          code == :event_based_gateway_receive_task_has_boundary
        end)

      assert message =~ "EventBasedGateway"
      assert message =~ "'EBG_1'"
      assert message =~ "Receive Task"
      assert message =~ "'RT_1'"
      assert message =~ "boundary events"
    end

    test "Receive Task with boundary NOT connected to EBG passes" do
      definitions =
        ebg_definitions(
          [
            %FlowNode{id: "S1", type: :start_event, type_data: %FlowNodeData.StartEvent{}, outgoing: ["F1"]},
            %FlowNode{
              id: "RT_1",
              type: :receive_task,
              type_data: %FlowNodeData.ReceiveTask{message_ref: "Msg_1"},
              incoming: ["F1"],
              outgoing: ["F_RT_End"],
              boundary_event_refs: ["BE_Timer"]
            },
            %FlowNode{
              id: "BE_Timer",
              type: :boundary_event,
              type_data: %FlowNodeData.BoundaryEvent{
                attached_to_ref: "RT_1",
                cancel_activity: true,
                event_definition: %EventDefinition.Timer{time_duration: "PT30S"}
              },
              outgoing: ["F_BE_End"]
            },
            %FlowNode{id: "E1", type: :end_event, type_data: %FlowNodeData.EndEvent{}, incoming: ["F_RT_End", "F_BE_End"]}
          ],
          [
            %SequenceFlow{id: "F1", source_ref: "S1", target_ref: "RT_1"},
            %SequenceFlow{id: "F_RT_End", source_ref: "RT_1", target_ref: "E1"},
            %SequenceFlow{id: "F_BE_End", source_ref: "BE_Timer", target_ref: "E1"}
          ],
          messages: [%MessageDefinition{id: "Msg_1", name: "test-msg"}]
        )

      assert {:ok, _} = Validator.validate(definitions)
    end
  end

  # -------------------------------------------------------------------------
  # Global flow-node ID uniqueness (subprocess start isolation)
  # -------------------------------------------------------------------------

  defp subprocess_node(id, inner_nodes, inner_flows) do
    %FlowNode{
      id: id,
      type: :sub_process,
      type_data: %FlowNodeData.SubProcess{
        triggered_by_event: false,
        flow_nodes: inner_nodes,
        sequence_flows: inner_flows
      }
    }
  end

  describe "validate/1 — global flow-node ID uniqueness" do
    test "duplicate id across top-level and inner subprocess scope is rejected" do
      # Inner start "S1" collides with the top-level start "S1".
      inner_nodes = [
        %FlowNode{id: "S1", type: :start_event, type_data: %FlowNodeData.StartEvent{}},
        %FlowNode{id: "Sub_End_1", type: :end_event, type_data: %FlowNodeData.EndEvent{}}
      ]

      inner_flows = [%SequenceFlow{id: "Sub_Flow_1", source_ref: "S1", target_ref: "Sub_End_1"}]

      definitions =
        minimal_valid_definitions(
          extra_nodes: [subprocess_node("SubProcess_1", inner_nodes, inner_flows)],
          extra_flows: [%SequenceFlow{id: "F2", source_ref: "S1", target_ref: "SubProcess_1"}]
        )

      assert {:error, violations} = Validator.validate(definitions)

      assert Enum.any?(violations, fn {code, message} ->
               code == :duplicate_flow_node_id and message =~ "'S1'"
             end)
    end

    test "all-unique ids across scopes produce no duplicate violation" do
      inner_nodes = [
        %FlowNode{id: "Sub_Start_1", type: :start_event, type_data: %FlowNodeData.StartEvent{}},
        %FlowNode{id: "Sub_End_1", type: :end_event, type_data: %FlowNodeData.EndEvent{}}
      ]

      inner_flows = [
        %SequenceFlow{id: "Sub_Flow_1", source_ref: "Sub_Start_1", target_ref: "Sub_End_1"}
      ]

      definitions =
        minimal_valid_definitions(
          extra_nodes: [subprocess_node("SubProcess_1", inner_nodes, inner_flows)],
          extra_flows: [%SequenceFlow{id: "F2", source_ref: "S1", target_ref: "SubProcess_1"}]
        )

      refute_violation_code(definitions, :duplicate_flow_node_id)
    end

    test "deep-nested duplicate id is caught" do
      # SubProcess_Outer > SubProcess_Inner, whose inner end "E1" collides with
      # the top-level end event "E1".
      innermost_nodes = [
        %FlowNode{id: "II_Start", type: :start_event, type_data: %FlowNodeData.StartEvent{}},
        %FlowNode{id: "E1", type: :end_event, type_data: %FlowNodeData.EndEvent{}}
      ]

      innermost_flows = [%SequenceFlow{id: "II_Flow", source_ref: "II_Start", target_ref: "E1"}]

      inner_subprocess = subprocess_node("SubProcess_Inner", innermost_nodes, innermost_flows)

      outer_nodes = [
        %FlowNode{id: "O_Start", type: :start_event, type_data: %FlowNodeData.StartEvent{}},
        inner_subprocess,
        %FlowNode{id: "O_End", type: :end_event, type_data: %FlowNodeData.EndEvent{}}
      ]

      outer_flows = [
        %SequenceFlow{id: "O_Flow_1", source_ref: "O_Start", target_ref: "SubProcess_Inner"},
        %SequenceFlow{id: "O_Flow_2", source_ref: "SubProcess_Inner", target_ref: "O_End"}
      ]

      definitions =
        minimal_valid_definitions(
          extra_nodes: [subprocess_node("SubProcess_Outer", outer_nodes, outer_flows)],
          extra_flows: [%SequenceFlow{id: "F2", source_ref: "S1", target_ref: "SubProcess_Outer"}]
        )

      assert {:error, violations} = Validator.validate(definitions)

      assert Enum.any?(violations, fn {code, message} ->
               code == :duplicate_flow_node_id and message =~ "'E1'"
             end)
    end

    test "duplicate id within the same top-level scope is caught" do
      definitions =
        minimal_valid_definitions(
          extra_nodes: [
            %FlowNode{id: "S1", type: :start_event, type_data: %FlowNodeData.StartEvent{}}
          ]
        )

      assert {:error, violations} = Validator.validate(definitions)

      assert Enum.any?(violations, fn {code, _message} ->
               code == :duplicate_flow_node_id
             end)
    end
  end

  # -------------------------------------------------------------------------
  # Event Subprocess test helpers
  # -------------------------------------------------------------------------

  # Wraps a standard main Start->End flow plus one Event Subprocess shell
  # (no incoming/outgoing sequence flows) carrying `esp_inner`. `globals` is
  # extra definitions-level XML (messages/signals/errors/escalations).
  defp esp_definition_xml(esp_inner, globals) do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
                      xmlns:evil="https://evilengine.dev/schema/bpmn"
                      id="Definitions_ESP">
      #{globals}
      <bpmn:process id="Process_ESP" isExecutable="true">
        <bpmn:extensionElements>
          <evil:version>1.0.0</evil:version>
        </bpmn:extensionElements>
        <bpmn:startEvent id="Main_Start">
          <bpmn:outgoing>Main_Flow</bpmn:outgoing>
        </bpmn:startEvent>
        <bpmn:endEvent id="Main_End">
          <bpmn:incoming>Main_Flow</bpmn:incoming>
        </bpmn:endEvent>
        <bpmn:sequenceFlow id="Main_Flow" sourceRef="Main_Start" targetRef="Main_End" />
        #{esp_inner}
      </bpmn:process>
    </bpmn:definitions>
    """
  end

  defp validate_esp(esp_inner, globals \\ "") do
    esp_inner
    |> esp_definition_xml(globals)
    |> parse_fixture_from_xml()
    |> Validator.validate()
  end

  defp transaction_node(id, inner_nodes, inner_flows, opts \\ []) do
    %FlowNode{
      id: id,
      type: :sub_process,
      type_data: %FlowNodeData.SubProcess{
        triggered_by_event: false,
        is_transaction: true,
        transaction_method: Keyword.get(opts, :method),
        flow_nodes: inner_nodes,
        sequence_flows: inner_flows
      }
    }
  end

  defp minimal_inner_scope(start_id, end_id, flow_id) do
    inner_nodes = [
      %FlowNode{id: start_id, type: :start_event, type_data: %FlowNodeData.StartEvent{}},
      %FlowNode{id: end_id, type: :end_event, type_data: %FlowNodeData.EndEvent{}}
    ]

    inner_flows = [%SequenceFlow{id: flow_id, source_ref: start_id, target_ref: end_id}]
    {inner_nodes, inner_flows}
  end

  describe "validate/1 — Cancel event transaction scope (E2.1)" do
    test "Cancel End Event inside a Transaction is valid" do
      {inner_nodes, inner_flows} = minimal_inner_scope("TX_Start", "TX_End", "TX_F1")

      cancel_end = %FlowNode{
        id: "TX_Cancel_End",
        type: :end_event,
        type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.Cancel{}}
      }

      tx = transaction_node("TX_1", inner_nodes ++ [cancel_end], inner_flows)

      cancel_boundary = %FlowNode{
        id: "CB_1",
        type: :boundary_event,
        type_data: %FlowNodeData.BoundaryEvent{
          event_definition: %EventDefinition.Cancel{},
          attached_to_ref: "TX_1",
          cancel_activity: true
        }
      }

      definitions =
        minimal_valid_definitions(
          extra_nodes: [tx, cancel_boundary],
          extra_flows: [
            %SequenceFlow{id: "F2", source_ref: "S1", target_ref: "TX_1"},
            %SequenceFlow{id: "F3", source_ref: "TX_1", target_ref: "E1"},
            %SequenceFlow{id: "F4", source_ref: "CB_1", target_ref: "E1"}
          ]
        )

      refute_violation_code(definitions, :cancel_end_outside_transaction)
      refute_violation_code(definitions, :cancel_boundary_not_on_transaction)
    end

    test "Cancel End Event outside a Transaction is rejected" do
      cancel_end = %FlowNode{
        id: "Cancel_End",
        type: :end_event,
        type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.Cancel{}}
      }

      definitions = minimal_valid_definitions(extra_nodes: [cancel_end])

      assert_violation_code(definitions, :cancel_end_outside_transaction)
    end

    test "Cancel Boundary Event on non-transaction host is rejected" do
      regular_task = %FlowNode{
        id: "Task_1",
        type: :user_task,
        type_data: %FlowNodeData.UserTask{}
      }

      cancel_boundary = %FlowNode{
        id: "CB_1",
        type: :boundary_event,
        type_data: %FlowNodeData.BoundaryEvent{
          event_definition: %EventDefinition.Cancel{},
          attached_to_ref: "Task_1",
          cancel_activity: true
        }
      }

      definitions = minimal_valid_definitions(extra_nodes: [regular_task, cancel_boundary])

      assert_violation_code(definitions, :cancel_boundary_not_on_transaction)
    end

    test "Cancel Boundary Event on a Transaction subprocess is valid" do
      {inner_nodes, inner_flows} = minimal_inner_scope("TX_Start", "TX_End", "TX_F1")
      tx = transaction_node("TX_1", inner_nodes, inner_flows)

      cancel_boundary = %FlowNode{
        id: "CB_1",
        type: :boundary_event,
        type_data: %FlowNodeData.BoundaryEvent{
          event_definition: %EventDefinition.Cancel{},
          attached_to_ref: "TX_1",
          cancel_activity: true
        }
      }

      definitions =
        minimal_valid_definitions(
          extra_nodes: [tx, cancel_boundary],
          extra_flows: [
            %SequenceFlow{id: "F2", source_ref: "S1", target_ref: "TX_1"},
            %SequenceFlow{id: "F3", source_ref: "TX_1", target_ref: "E1"},
            %SequenceFlow{id: "F4", source_ref: "CB_1", target_ref: "E1"}
          ]
        )

      refute_violation_code(definitions, :cancel_boundary_not_on_transaction)
    end

    test "Cancel Boundary Event on a regular SubProcess is rejected" do
      {inner_nodes, inner_flows} = minimal_inner_scope("SP_Start", "SP_End", "SP_F1")

      regular_sp = %FlowNode{
        id: "SP_1",
        type: :sub_process,
        type_data: %FlowNodeData.SubProcess{
          triggered_by_event: false,
          is_transaction: false,
          flow_nodes: inner_nodes,
          sequence_flows: inner_flows
        }
      }

      cancel_boundary = %FlowNode{
        id: "CB_1",
        type: :boundary_event,
        type_data: %FlowNodeData.BoundaryEvent{
          event_definition: %EventDefinition.Cancel{},
          attached_to_ref: "SP_1",
          cancel_activity: true
        }
      }

      definitions =
        minimal_valid_definitions(
          extra_nodes: [regular_sp, cancel_boundary],
          extra_flows: [
            %SequenceFlow{id: "F2", source_ref: "S1", target_ref: "SP_1"},
            %SequenceFlow{id: "F3", source_ref: "SP_1", target_ref: "E1"},
            %SequenceFlow{id: "F4", source_ref: "CB_1", target_ref: "E1"}
          ]
        )

      assert_violation_code(definitions, :cancel_boundary_not_on_transaction)
    end
  end

  describe "validate/1 — Nested transaction rejection (E2.2)" do
    test "Transaction directly containing another Transaction is rejected" do
      {inner_inner_nodes, inner_inner_flows} =
        minimal_inner_scope("INNER_Start", "INNER_End", "INNER_F1")

      inner_tx = transaction_node("Inner_TX", inner_inner_nodes, inner_inner_flows)

      inner_nodes = [
        %FlowNode{id: "TX_Start", type: :start_event, type_data: %FlowNodeData.StartEvent{}},
        inner_tx,
        %FlowNode{id: "TX_End", type: :end_event, type_data: %FlowNodeData.EndEvent{}}
      ]

      inner_flows = [
        %SequenceFlow{id: "TF1", source_ref: "TX_Start", target_ref: "Inner_TX"},
        %SequenceFlow{id: "TF2", source_ref: "Inner_TX", target_ref: "TX_End"}
      ]

      outer_tx = transaction_node("Outer_TX", inner_nodes, inner_flows)

      definitions =
        minimal_valid_definitions(
          extra_nodes: [outer_tx],
          extra_flows: [
            %SequenceFlow{id: "F2", source_ref: "S1", target_ref: "Outer_TX"},
            %SequenceFlow{id: "F3", source_ref: "Outer_TX", target_ref: "E1"}
          ]
        )

      assert_violation_code(definitions, :nested_transaction)
    end

    test "Transaction containing an embedded subprocess (non-transaction) is valid" do
      {inner_sp_nodes, inner_sp_flows} =
        minimal_inner_scope("SP_Start", "SP_End", "SP_F1")

      regular_sp = subprocess_node("SP_Inside", inner_sp_nodes, inner_sp_flows)

      tx_inner_nodes = [
        %FlowNode{id: "TX_Start", type: :start_event, type_data: %FlowNodeData.StartEvent{}},
        regular_sp,
        %FlowNode{id: "TX_End", type: :end_event, type_data: %FlowNodeData.EndEvent{}}
      ]

      tx_inner_flows = [
        %SequenceFlow{id: "TF1", source_ref: "TX_Start", target_ref: "SP_Inside"},
        %SequenceFlow{id: "TF2", source_ref: "SP_Inside", target_ref: "TX_End"}
      ]

      tx = transaction_node("TX_1", tx_inner_nodes, tx_inner_flows)

      definitions =
        minimal_valid_definitions(
          extra_nodes: [tx],
          extra_flows: [
            %SequenceFlow{id: "F2", source_ref: "S1", target_ref: "TX_1"},
            %SequenceFlow{id: "F3", source_ref: "TX_1", target_ref: "E1"}
          ]
        )

      refute_violation_code(definitions, :nested_transaction)
    end

    test "top-level process with two sibling Transactions is valid" do
      {inner1, flows1} = minimal_inner_scope("TX1_Start", "TX1_End", "TX1_F1")
      {inner2, flows2} = minimal_inner_scope("TX2_Start", "TX2_End", "TX2_F1")
      tx1 = transaction_node("TX_1", inner1, flows1)
      tx2 = transaction_node("TX_2", inner2, flows2)

      definitions =
        minimal_valid_definitions(
          extra_nodes: [tx1, tx2],
          extra_flows: [
            %SequenceFlow{id: "F2", source_ref: "S1", target_ref: "TX_1"},
            %SequenceFlow{id: "F3", source_ref: "TX_1", target_ref: "TX_2"},
            %SequenceFlow{id: "F4", source_ref: "TX_2", target_ref: "E1"}
          ]
        )

      refute_violation_code(definitions, :nested_transaction)
    end
  end

  describe "validate/1 — Transaction full XML round-trip (E2.4)" do
    test "valid transaction with Cancel End and Cancel Boundary parses and validates" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
                        xmlns:evil="https://evilengine.dev/schema/bpmn"
                        id="Defs_TX_Valid">
        <bpmn:process id="Process_TX" isExecutable="true">
          <bpmn:extensionElements><evil:version>1.0.0</evil:version></bpmn:extensionElements>
          <bpmn:startEvent id="Start_1"><bpmn:outgoing>F1</bpmn:outgoing></bpmn:startEvent>
          <bpmn:transaction id="TX_1" name="My Transaction">
            <bpmn:startEvent id="TX_Start"><bpmn:outgoing>TF1</bpmn:outgoing></bpmn:startEvent>
            <bpmn:task id="TX_Task"><bpmn:incoming>TF1</bpmn:incoming><bpmn:outgoing>TF2</bpmn:outgoing></bpmn:task>
            <bpmn:endEvent id="TX_Cancel_End">
              <bpmn:cancelEventDefinition/>
              <bpmn:incoming>TF2</bpmn:incoming>
            </bpmn:endEvent>
            <bpmn:sequenceFlow id="TF1" sourceRef="TX_Start" targetRef="TX_Task"/>
            <bpmn:sequenceFlow id="TF2" sourceRef="TX_Task" targetRef="TX_Cancel_End"/>
            <bpmn:incoming>F1</bpmn:incoming>
            <bpmn:outgoing>F2</bpmn:outgoing>
          </bpmn:transaction>
          <bpmn:boundaryEvent id="Cancel_Boundary" attachedToRef="TX_1" cancelActivity="true">
            <bpmn:cancelEventDefinition/>
            <bpmn:outgoing>F3</bpmn:outgoing>
          </bpmn:boundaryEvent>
          <bpmn:endEvent id="End_Cancelled"><bpmn:incoming>F3</bpmn:incoming></bpmn:endEvent>
          <bpmn:endEvent id="End_Success"><bpmn:incoming>F2</bpmn:incoming></bpmn:endEvent>
          <bpmn:sequenceFlow id="F1" sourceRef="Start_1" targetRef="TX_1"/>
          <bpmn:sequenceFlow id="F2" sourceRef="TX_1" targetRef="End_Success"/>
          <bpmn:sequenceFlow id="F3" sourceRef="Cancel_Boundary" targetRef="End_Cancelled"/>
        </bpmn:process>
      </bpmn:definitions>
      """

      definitions = parse_fixture_from_xml(xml)

      refute_violation_code(definitions, :cancel_end_outside_transaction)
      refute_violation_code(definitions, :cancel_boundary_not_on_transaction)
      refute_violation_code(definitions, :nested_transaction)
    end
  end

  # -------------------------------------------------------------------------
  # Standard Loop characteristics
  # -------------------------------------------------------------------------

  describe "validate/1 — standard loop missing loopCondition" do
    test "rejects standard loop without loopCondition" do
      definitions =
        minimal_valid_definitions(
          extra_nodes: [
            %FlowNode{
              id: "Task_Loop",
              type: :script_task,
              type_data: %FlowNodeData.ScriptTask{script_format: "feel", script: "1 + 1"},
              standard_loop: %StandardLoop{loop_condition: nil, loop_maximum: 10},
              incoming: ["F_in"],
              outgoing: ["F_out"]
            }
          ],
          extra_flows: [
            %SequenceFlow{id: "F_in", source_ref: "S1", target_ref: "Task_Loop"},
            %SequenceFlow{id: "F_out", source_ref: "Task_Loop", target_ref: "E1"}
          ]
        )

      assert_violation_code(definitions, :standard_loop_missing_condition)
    end

    test "error message references the element id" do
      definitions =
        minimal_valid_definitions(
          extra_nodes: [
            %FlowNode{
              id: "Task_Loop",
              type: :script_task,
              type_data: %FlowNodeData.ScriptTask{script_format: "feel", script: "1 + 1"},
              standard_loop: %StandardLoop{loop_condition: nil, loop_maximum: 10},
              incoming: ["F_in"],
              outgoing: ["F_out"]
            }
          ],
          extra_flows: [
            %SequenceFlow{id: "F_in", source_ref: "S1", target_ref: "Task_Loop"},
            %SequenceFlow{id: "F_out", source_ref: "Task_Loop", target_ref: "E1"}
          ]
        )

      {:error, violations} = Validator.validate(definitions)

      {_, message} =
        Enum.find(violations, fn {code, _} -> code == :standard_loop_missing_condition end)

      assert message =~ "Task_Loop"
      assert message =~ "loopCondition"
    end
  end

  describe "validate/1 — standard loop with valid loopCondition passes" do
    test "does not reject standard loop with loopCondition present" do
      definitions =
        minimal_valid_definitions(
          extra_nodes: [
            %FlowNode{
              id: "Task_Loop",
              type: :script_task,
              type_data: %FlowNodeData.ScriptTask{script_format: "feel", script: "1 + 1"},
              standard_loop: %StandardLoop{
                loop_condition: "token.counter < 5",
                loop_maximum: 10
              },
              incoming: ["F_in"],
              outgoing: ["F_out"]
            }
          ],
          extra_flows: [
            %SequenceFlow{id: "F_in", source_ref: "S1", target_ref: "Task_Loop"},
            %SequenceFlow{id: "F_out", source_ref: "Task_Loop", target_ref: "E1"}
          ]
        )

      refute_violation_code(definitions, :standard_loop_missing_condition)
    end
  end

  describe "validate/1 — standard loop invalid loopMaximum" do
    test "rejects loopMaximum of 0" do
      definitions =
        minimal_valid_definitions(
          extra_nodes: [
            %FlowNode{
              id: "Task_Loop",
              type: :script_task,
              type_data: %FlowNodeData.ScriptTask{script_format: "feel", script: "1 + 1"},
              standard_loop: %StandardLoop{
                loop_condition: "token.counter < 5",
                loop_maximum: 0
              },
              incoming: ["F_in"],
              outgoing: ["F_out"]
            }
          ],
          extra_flows: [
            %SequenceFlow{id: "F_in", source_ref: "S1", target_ref: "Task_Loop"},
            %SequenceFlow{id: "F_out", source_ref: "Task_Loop", target_ref: "E1"}
          ]
        )

      assert_violation_code(definitions, :standard_loop_invalid_maximum)
    end

    test "rejects negative loopMaximum" do
      definitions =
        minimal_valid_definitions(
          extra_nodes: [
            %FlowNode{
              id: "Task_Loop",
              type: :script_task,
              type_data: %FlowNodeData.ScriptTask{script_format: "feel", script: "1 + 1"},
              standard_loop: %StandardLoop{
                loop_condition: "token.counter < 5",
                loop_maximum: -3
              },
              incoming: ["F_in"],
              outgoing: ["F_out"]
            }
          ],
          extra_flows: [
            %SequenceFlow{id: "F_in", source_ref: "S1", target_ref: "Task_Loop"},
            %SequenceFlow{id: "F_out", source_ref: "Task_Loop", target_ref: "E1"}
          ]
        )

      assert_violation_code(definitions, :standard_loop_invalid_maximum)
    end
  end

  describe "validate/1 — loopCardinality is not supported" do
    test "rejects a multi-instance activity that declares loopCardinality" do
      definitions =
        minimal_valid_definitions(
          extra_nodes: [
            %FlowNode{
              id: "Task_MI",
              type: :task,
              type_data: %FlowNodeData.Task{},
              multi_instance: %MultiInstance{
                collection_expression: "token.items",
                loop_cardinality: "5"
              },
              incoming: ["F_in"],
              outgoing: ["F_out"]
            }
          ],
          extra_flows: [
            %SequenceFlow{id: "F_in", source_ref: "S1", target_ref: "Task_MI"},
            %SequenceFlow{id: "F_out", source_ref: "Task_MI", target_ref: "E1"}
          ]
        )

      assert_violation_code(definitions, :loop_cardinality_not_supported)
    end

    test "parser_coverage_multi_instance.bpmn is rejected for loopCardinality" do
      definitions = parse_fixture("parser_coverage_multi_instance.bpmn")
      assert_violation_code(definitions, :loop_cardinality_not_supported)
    end
  end

  describe "validate/1 — MI and standard loop mutual exclusivity" do
    test "rejects activity with both multiInstance and standardLoop" do
      definitions =
        minimal_valid_definitions(
          extra_nodes: [
            %FlowNode{
              id: "Task_Both",
              type: :task,
              type_data: %FlowNodeData.Task{},
              multi_instance: %MultiInstance{
                collection_expression: "token.items"
              },
              standard_loop: %StandardLoop{
                loop_condition: "token.counter < 5",
                loop_maximum: 10
              },
              incoming: ["F_in"],
              outgoing: ["F_out"]
            }
          ],
          extra_flows: [
            %SequenceFlow{id: "F_in", source_ref: "S1", target_ref: "Task_Both"},
            %SequenceFlow{id: "F_out", source_ref: "Task_Both", target_ref: "E1"}
          ]
        )

      assert_violation_code(definitions, :loop_mutual_exclusivity)
    end

    test "error message mentions both loop types" do
      definitions =
        minimal_valid_definitions(
          extra_nodes: [
            %FlowNode{
              id: "Task_Both",
              type: :task,
              type_data: %FlowNodeData.Task{},
              multi_instance: %MultiInstance{
                collection_expression: "token.items"
              },
              standard_loop: %StandardLoop{
                loop_condition: "token.counter < 5",
                loop_maximum: 10
              },
              incoming: ["F_in"],
              outgoing: ["F_out"]
            }
          ],
          extra_flows: [
            %SequenceFlow{id: "F_in", source_ref: "S1", target_ref: "Task_Both"},
            %SequenceFlow{id: "F_out", source_ref: "Task_Both", target_ref: "E1"}
          ]
        )

      {:error, violations} = Validator.validate(definitions)

      {_, message} =
        Enum.find(violations, fn {code, _} -> code == :loop_mutual_exclusivity end)

      assert message =~ "multiInstanceLoopCharacteristics"
      assert message =~ "standardLoopCharacteristics"
    end
  end

  describe "validate/1 — standard loop full XML round-trip" do
    test "valid standard loop fixture passes loop-related checks" do
      definitions = parse_fixture("parser_coverage_standard_loop.bpmn")

      refute_violation_code(definitions, :standard_loop_missing_condition)
      refute_violation_code(definitions, :standard_loop_invalid_maximum)
      refute_violation_code(definitions, :standard_loop_no_maximum)
      refute_violation_code(definitions, :loop_mutual_exclusivity)
    end
  end

  # ---------------------------------------------------------------------------
  # Ad-hoc SubProcess validation
  # ---------------------------------------------------------------------------

  defp adhoc_subprocess_node(id, inner_nodes, inner_flows, opts \\ []) do
    %FlowNode{
      id: id,
      type: :sub_process,
      type_data: %FlowNodeData.SubProcess{
        triggered_by_event: false,
        is_ad_hoc: true,
        adhoc_ordering: Keyword.get(opts, :adhoc_ordering, :parallel),
        cancel_remaining_instances: Keyword.get(opts, :cancel_remaining_instances, true),
        implementation: Keyword.get(opts, :implementation),
        active_elements_expression: Keyword.get(opts, :active_elements_expression),
        flow_nodes: inner_nodes,
        sequence_flows: inner_flows
      }
    }
  end

  describe "validate/1 — Ad-hoc SubProcess structural checks" do
    test "valid ad-hoc subprocess with activities and no start/end events passes" do
      inner_task = %FlowNode{
        id: "AH_Task_1",
        type: :task,
        type_data: %FlowNodeData.Task{}
      }

      adhoc = adhoc_subprocess_node("AdHoc_1", [inner_task], [])

      definitions =
        minimal_valid_definitions(
          extra_nodes: [adhoc],
          extra_flows: [
            %SequenceFlow{id: "F2", source_ref: "S1", target_ref: "AdHoc_1"},
            %SequenceFlow{id: "F3", source_ref: "AdHoc_1", target_ref: "E1"}
          ]
        )

      refute_violation_code(definitions, :adhoc_subprocess_empty)
      refute_violation_code(definitions, :adhoc_subprocess_has_start_event)
      refute_violation_code(definitions, :adhoc_subprocess_has_end_event)
      refute_violation_code(definitions, :adhoc_sequential_missing_active_elements)
      refute_violation_code(definitions, :adhoc_subprocess_empty_implementation)
      refute_violation_code(definitions, :nested_adhoc_subprocess)
      refute_violation_code(definitions, :adhoc_inside_event_subprocess)
    end

    test "ad-hoc subprocess with no activities is rejected" do
      gateway = %FlowNode{
        id: "AH_GW",
        type: :exclusive_gateway,
        type_data: %FlowNodeData.ExclusiveGateway{}
      }

      adhoc = adhoc_subprocess_node("AdHoc_1", [gateway], [])

      definitions =
        minimal_valid_definitions(
          extra_nodes: [adhoc],
          extra_flows: [
            %SequenceFlow{id: "F2", source_ref: "S1", target_ref: "AdHoc_1"},
            %SequenceFlow{id: "F3", source_ref: "AdHoc_1", target_ref: "E1"}
          ]
        )

      assert_violation_code(definitions, :adhoc_subprocess_empty)
    end

    test "ad-hoc subprocess containing a start event is rejected" do
      inner_task = %FlowNode{
        id: "AH_Task_1",
        type: :task,
        type_data: %FlowNodeData.Task{}
      }

      inner_start = %FlowNode{
        id: "AH_Start",
        type: :start_event,
        type_data: %FlowNodeData.StartEvent{}
      }

      adhoc = adhoc_subprocess_node("AdHoc_1", [inner_task, inner_start], [])

      definitions =
        minimal_valid_definitions(
          extra_nodes: [adhoc],
          extra_flows: [
            %SequenceFlow{id: "F2", source_ref: "S1", target_ref: "AdHoc_1"},
            %SequenceFlow{id: "F3", source_ref: "AdHoc_1", target_ref: "E1"}
          ]
        )

      assert_violation_code(definitions, :adhoc_subprocess_has_start_event)
    end

    test "ad-hoc subprocess containing an end event is rejected" do
      inner_task = %FlowNode{
        id: "AH_Task_1",
        type: :task,
        type_data: %FlowNodeData.Task{}
      }

      inner_end = %FlowNode{
        id: "AH_End",
        type: :end_event,
        type_data: %FlowNodeData.EndEvent{}
      }

      adhoc = adhoc_subprocess_node("AdHoc_1", [inner_task, inner_end], [])

      definitions =
        minimal_valid_definitions(
          extra_nodes: [adhoc],
          extra_flows: [
            %SequenceFlow{id: "F2", source_ref: "S1", target_ref: "AdHoc_1"},
            %SequenceFlow{id: "F3", source_ref: "AdHoc_1", target_ref: "E1"}
          ]
        )

      assert_violation_code(definitions, :adhoc_subprocess_has_end_event)
    end

    test "sequential ad-hoc without implementation or activeElements is rejected" do
      inner_task = %FlowNode{
        id: "AH_Task_1",
        type: :task,
        type_data: %FlowNodeData.Task{}
      }

      adhoc =
        adhoc_subprocess_node("AdHoc_1", [inner_task], [],
          adhoc_ordering: :sequential
        )

      definitions =
        minimal_valid_definitions(
          extra_nodes: [adhoc],
          extra_flows: [
            %SequenceFlow{id: "F2", source_ref: "S1", target_ref: "AdHoc_1"},
            %SequenceFlow{id: "F3", source_ref: "AdHoc_1", target_ref: "E1"}
          ]
        )

      assert_violation_code(definitions, :adhoc_sequential_missing_active_elements)
    end

    test "sequential ad-hoc with implementation passes" do
      inner_task = %FlowNode{
        id: "AH_Task_1",
        type: :task,
        type_data: %FlowNodeData.Task{}
      }

      adhoc =
        adhoc_subprocess_node("AdHoc_1", [inner_task], [],
          adhoc_ordering: :sequential,
          implementation: "my-plugin"
        )

      definitions =
        minimal_valid_definitions(
          extra_nodes: [adhoc],
          extra_flows: [
            %SequenceFlow{id: "F2", source_ref: "S1", target_ref: "AdHoc_1"},
            %SequenceFlow{id: "F3", source_ref: "AdHoc_1", target_ref: "E1"}
          ]
        )

      refute_violation_code(definitions, :adhoc_sequential_missing_active_elements)
    end

    test "sequential ad-hoc with activeElements expression passes" do
      inner_task = %FlowNode{
        id: "AH_Task_1",
        type: :task,
        type_data: %FlowNodeData.Task{}
      }

      adhoc =
        adhoc_subprocess_node("AdHoc_1", [inner_task], [],
          adhoc_ordering: :sequential,
          active_elements_expression: "[\"AH_Task_1\"]"
        )

      definitions =
        minimal_valid_definitions(
          extra_nodes: [adhoc],
          extra_flows: [
            %SequenceFlow{id: "F2", source_ref: "S1", target_ref: "AdHoc_1"},
            %SequenceFlow{id: "F3", source_ref: "AdHoc_1", target_ref: "E1"}
          ]
        )

      refute_violation_code(definitions, :adhoc_sequential_missing_active_elements)
    end

    test "ad-hoc subprocess with empty implementation string is rejected" do
      inner_task = %FlowNode{
        id: "AH_Task_1",
        type: :task,
        type_data: %FlowNodeData.Task{}
      }

      adhoc =
        adhoc_subprocess_node("AdHoc_1", [inner_task], [],
          implementation: "   "
        )

      definitions =
        minimal_valid_definitions(
          extra_nodes: [adhoc],
          extra_flows: [
            %SequenceFlow{id: "F2", source_ref: "S1", target_ref: "AdHoc_1"},
            %SequenceFlow{id: "F3", source_ref: "AdHoc_1", target_ref: "E1"}
          ]
        )

      assert_violation_code(definitions, :adhoc_subprocess_empty_implementation)
    end

    test "parallel ad-hoc without implementation or activeElements passes" do
      inner_task = %FlowNode{
        id: "AH_Task_1",
        type: :task,
        type_data: %FlowNodeData.Task{}
      }

      adhoc =
        adhoc_subprocess_node("AdHoc_1", [inner_task], [],
          adhoc_ordering: :parallel
        )

      definitions =
        minimal_valid_definitions(
          extra_nodes: [adhoc],
          extra_flows: [
            %SequenceFlow{id: "F2", source_ref: "S1", target_ref: "AdHoc_1"},
            %SequenceFlow{id: "F3", source_ref: "AdHoc_1", target_ref: "E1"}
          ]
        )

      refute_violation_code(definitions, :adhoc_sequential_missing_active_elements)
    end

    test "ad-hoc inner activities are not flagged as orphan nodes" do
      inner_task_1 = %FlowNode{
        id: "AH_Task_1",
        type: :task,
        type_data: %FlowNodeData.Task{}
      }

      inner_task_2 = %FlowNode{
        id: "AH_Task_2",
        type: :service_task,
        type_data: %FlowNodeData.ServiceTask{implementation: "http"}
      }

      adhoc = adhoc_subprocess_node("AdHoc_1", [inner_task_1, inner_task_2], [])

      definitions =
        minimal_valid_definitions(
          extra_nodes: [adhoc],
          extra_flows: [
            %SequenceFlow{id: "F2", source_ref: "S1", target_ref: "AdHoc_1"},
            %SequenceFlow{id: "F3", source_ref: "AdHoc_1", target_ref: "E1"}
          ]
        )

      case Validator.validate(definitions) do
        {:ok, _} ->
          :ok

        {:error, violations} ->
          orphan_violations =
            Enum.filter(violations, fn {code, _message} -> code == :orphan_node end)

          assert orphan_violations == [],
                 "Expected no orphan-node violations for ad-hoc inner activities, " <>
                   "but got: #{inspect(orphan_violations)}"
      end
    end
  end

  describe "validate/1 — Ad-hoc SubProcess nesting restrictions" do
    test "ad-hoc inside ad-hoc is rejected" do
      inner_task = %FlowNode{
        id: "Inner_Task",
        type: :task,
        type_data: %FlowNodeData.Task{}
      }

      inner_adhoc = adhoc_subprocess_node("Inner_AdHoc", [inner_task], [])

      outer_adhoc =
        adhoc_subprocess_node("Outer_AdHoc", [inner_adhoc], [])

      definitions =
        minimal_valid_definitions(
          extra_nodes: [outer_adhoc],
          extra_flows: [
            %SequenceFlow{id: "F2", source_ref: "S1", target_ref: "Outer_AdHoc"},
            %SequenceFlow{id: "F3", source_ref: "Outer_AdHoc", target_ref: "E1"}
          ]
        )

      assert_violation_code(definitions, :nested_adhoc_subprocess)
    end

    test "ad-hoc inside event subprocess is rejected" do
      inner_task = %FlowNode{
        id: "AH_Task",
        type: :task,
        type_data: %FlowNodeData.Task{}
      }

      inner_adhoc = adhoc_subprocess_node("Inner_AdHoc", [inner_task], [])

      esp_start = %FlowNode{
        id: "ESP_Start",
        type: :start_event,
        type_data: %FlowNodeData.StartEvent{
          event_definition: %EventDefinition.Timer{time_duration: "PT1H"},
          is_interrupting: true
        }
      }

      esp = %FlowNode{
        id: "ESP_1",
        type: :sub_process,
        type_data: %FlowNodeData.SubProcess{
          triggered_by_event: true,
          flow_nodes: [esp_start, inner_adhoc],
          sequence_flows: [
            %SequenceFlow{id: "ESP_F1", source_ref: "ESP_Start", target_ref: "Inner_AdHoc"}
          ]
        }
      }

      definitions =
        minimal_valid_definitions(
          extra_nodes: [esp],
          extra_flows: []
        )

      assert_violation_code(definitions, :adhoc_inside_event_subprocess)
    end

    test "ad-hoc inside regular subprocess is allowed" do
      inner_task = %FlowNode{
        id: "AH_Task",
        type: :task,
        type_data: %FlowNodeData.Task{}
      }

      inner_adhoc = adhoc_subprocess_node("Inner_AdHoc", [inner_task], [])

      sp_start = %FlowNode{
        id: "SP_Start",
        type: :start_event,
        type_data: %FlowNodeData.StartEvent{}
      }

      sp_end = %FlowNode{
        id: "SP_End",
        type: :end_event,
        type_data: %FlowNodeData.EndEvent{}
      }

      regular_sp = %FlowNode{
        id: "SP_1",
        type: :sub_process,
        type_data: %FlowNodeData.SubProcess{
          triggered_by_event: false,
          flow_nodes: [sp_start, inner_adhoc, sp_end],
          sequence_flows: [
            %SequenceFlow{id: "SP_F1", source_ref: "SP_Start", target_ref: "Inner_AdHoc"},
            %SequenceFlow{id: "SP_F2", source_ref: "Inner_AdHoc", target_ref: "SP_End"}
          ]
        }
      }

      definitions =
        minimal_valid_definitions(
          extra_nodes: [regular_sp],
          extra_flows: [
            %SequenceFlow{id: "F2", source_ref: "S1", target_ref: "SP_1"},
            %SequenceFlow{id: "F3", source_ref: "SP_1", target_ref: "E1"}
          ]
        )

      refute_violation_code(definitions, :nested_adhoc_subprocess)
      refute_violation_code(definitions, :adhoc_inside_event_subprocess)
    end
  end
end
