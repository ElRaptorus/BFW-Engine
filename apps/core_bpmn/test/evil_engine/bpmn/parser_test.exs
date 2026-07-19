defmodule EvilEngine.BPMN.ParserTest do
  use ExUnit.Case, async: true

  alias EvilEngine.BPMN.Model.Definitions
  alias EvilEngine.BPMN.Model.EscalationDefinition
  alias EvilEngine.BPMN.Model.EventDefinition
  alias EvilEngine.BPMN.Model.FlowNode
  alias EvilEngine.BPMN.Model.FlowNodeData
  alias EvilEngine.BPMN.Model.LinterRulesetScore
  alias EvilEngine.BPMN.Model.Mapping
  alias EvilEngine.BPMN.Model.MultiInstance
  alias EvilEngine.BPMN.Model.Process, as: BpmnProcess
  alias EvilEngine.BPMN.Model.SequenceFlow
  alias EvilEngine.BPMN.Model.SignalDefinition
  alias EvilEngine.BPMN.Model.StandardLoop
  alias EvilEngine.BPMN.Parser

  @fixtures_dir Path.join([__DIR__, "..", "..", "fixtures", "bpmns"])

  defp read_fixture(name), do: File.read!(Path.join(@fixtures_dir, name))

  defp find_node(%BpmnProcess{} = process, id) do
    Enum.find(process.flow_nodes, &(&1.id == id))
  end

  # Builds a process with a single Event Subprocess whose start event carries
  # `event_def_xml` and the optional `start_attrs` (e.g. `isInterrupting="false"`).
  defp esp_start_xml(event_def_xml, start_attrs) do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
                      xmlns:evil="https://evilengine.dev/schema/bpmn"
                      id="Definitions_1">
      <bpmn:process id="Process_1" isExecutable="true">
        <bpmn:extensionElements>
          <evil:version>1.0.0</evil:version>
        </bpmn:extensionElements>
        <bpmn:subProcess id="ESP_1" triggeredByEvent="true">
          <bpmn:startEvent id="ESP_Start_1" #{start_attrs}>
            #{event_def_xml}
          </bpmn:startEvent>
        </bpmn:subProcess>
      </bpmn:process>
    </bpmn:definitions>
    """
  end

  defp esp_start_event(%Definitions{processes: [process | _]}) do
    esp = Enum.find(process.flow_nodes, &(&1.id == "ESP_1"))
    Enum.find(esp.type_data.flow_nodes, &(&1.id == "ESP_Start_1"))
  end

  describe "parse/1 — minimal valid BPMN" do
    test "returns {:ok, %Definitions{}}" do
      xml = read_fixture("minimal_valid.bpmn")
      assert {:ok, %Definitions{}} = Parser.parse(xml)
    end

    test "extracts process ID, name, version, and executable flag" do
      {:ok, definitions} = Parser.parse(read_fixture("minimal_valid.bpmn"))
      [process] = definitions.processes

      assert process.id == "Process_1"
      assert process.name == "Minimal Valid"
      assert process.version == "1.0.0"
      assert process.is_executable == true
    end

    test "extracts flow nodes with correct types" do
      {:ok, definitions} = Parser.parse(read_fixture("minimal_valid.bpmn"))
      [process] = definitions.processes

      assert length(process.flow_nodes) == 2
      types = Enum.map(process.flow_nodes, & &1.type) |> Enum.sort()
      assert types == [:end_event, :start_event]
    end

    test "extracts sequence flows with source/target refs" do
      {:ok, definitions} = Parser.parse(read_fixture("minimal_valid.bpmn"))
      [process] = definitions.processes
      [sequence_flow] = process.sequence_flows

      assert sequence_flow.id == "Flow_1"
      assert sequence_flow.source_ref == "Start_1"
      assert sequence_flow.target_ref == "End_1"
    end

    test "start event gets EventDefinition.None by default" do
      {:ok, definitions} = Parser.parse(read_fixture("minimal_valid.bpmn"))
      [process] = definitions.processes

      start = Enum.find(process.flow_nodes, &(&1.type == :start_event))
      assert %FlowNodeData.StartEvent{event_definition: %EventDefinition.None{}} = start.type_data
    end

    test "preserves raw XML" do
      xml = read_fixture("minimal_valid.bpmn")
      {:ok, definitions} = Parser.parse(xml)
      assert definitions.raw_xml == xml
    end
  end

  describe "parse/1 — multi-process with extensions" do
    setup do
      {:ok, definitions} = Parser.parse(read_fixture("multi_process.bpmn"))
      %{definitions: definitions}
    end

    test "extracts two processes", %{definitions: definitions} do
      assert length(definitions.processes) == 2
    end

    test "extracts global message definitions", %{definitions: definitions} do
      assert [message] = definitions.messages
      assert message.id == "Msg_1"
      assert message.name == "OrderReceived"
    end

    test "extracts global signal definitions", %{definitions: definitions} do
      assert [signal] = definitions.signals
      assert signal.id == "Sig_1"
      assert signal.name == "AllDone"
    end

    test "extracts global error definitions", %{definitions: definitions} do
      assert [error] = definitions.errors
      assert error.id == "Err_1"
      assert error.error_code == "ERR_TIMEOUT"
    end

    test "extracts global escalation definitions", %{definitions: definitions} do
      assert [escalation] = definitions.escalations
      assert escalation.id == "Esc_1"
      assert escalation.escalation_code == "ESC_REVIEW"
    end

    test "message start event carries message_ref", %{definitions: definitions} do
      [main | _] = definitions.processes
      start = Enum.find(main.flow_nodes, &(&1.type == :start_event))

      assert %FlowNodeData.StartEvent{
               event_definition: %EventDefinition.Message{message_ref: "Msg_1"}
             } = start.type_data
    end

    test "signal end event carries signal_ref", %{definitions: definitions} do
      [main | _] = definitions.processes
      end_evt = Enum.find(main.flow_nodes, &(&1.type == :end_event))

      assert %FlowNodeData.EndEvent{
               event_definition: %EventDefinition.Signal{signal_ref: "Sig_1"}
             } = end_evt.type_data
    end

    test "user task carries assignees and priority", %{definitions: definitions} do
      [main | _] = definitions.processes

      ut =
        Enum.find(main.flow_nodes, fn %FlowNode{type: t} -> t == :user_task end)

      assert %FlowNodeData.UserTask{} = ut.type_data
      assert ut.type_data.assignees_expression == "clerk_role"
      assert ut.type_data.due_date == "2026-12-31T23:59:59Z"
      assert ut.type_data.priority == 5
    end

    test "service task carries implementation from standard attribute", %{
      definitions: definitions
    } do
      [main | _] = definitions.processes

      st =
        Enum.find(main.flow_nodes, fn %FlowNode{type: t} -> t == :service_task end)

      assert %FlowNodeData.ServiceTask{} = st.type_data
      assert st.type_data.implementation == "http"
    end

    test "script task with inline script parses all fields and data pipeline", %{
      definitions: definitions
    } do
      [main | _] = definitions.processes

      script_node =
        Enum.find(main.flow_nodes, fn %FlowNode{} = n ->
          n.id == "Script_1"
        end)

      assert %FlowNodeData.ScriptTask{} = script_node.type_data
      assert script_node.type_data.script_format == "feel"
      assert script_node.type_data.script == "token.amount * 1.19"
      assert script_node.type_data.script_ref == nil

      assert script_node.type_data.payload_contract == %{
               "type" => "object",
               "required" => ["amount"]
             }

      assert script_node.type_data.result_contract == %{"type" => "object"}
      assert [%{source: "token.raw", target: "amount"}] = script_node.type_data.in_mappings
      assert [%{source: "token.result", target: "taxed"}] = script_node.type_data.out_mappings
    end

    test "script task with evil:scriptRef parses ref as extension element", %{
      definitions: definitions
    } do
      [main | _] = definitions.processes

      script_node =
        Enum.find(main.flow_nodes, fn %FlowNode{} = n ->
          n.id == "Script_2"
        end)

      assert %FlowNodeData.ScriptTask{} = script_node.type_data
      assert script_node.type_data.script_ref == "my_validator"
      assert script_node.type_data.script == nil
      assert script_node.type_data.script_format == nil
    end

    test "extracts correlation key on process", %{definitions: definitions} do
      [main | _] = definitions.processes
      assert main.correlation_key == "order.customerId"
    end

    test "extracts lanes", %{definitions: definitions} do
      [main | _] = definitions.processes
      assert [lane] = main.lanes
      assert lane.id == "Lane_1"
      assert lane.name == "Clerk"
      assert "Task_1" in lane.flow_node_refs
    end

    test "extracts data objects and references", %{definitions: definitions} do
      [main | _] = definitions.processes
      assert [do_obj] = main.data_objects
      assert do_obj.id == "DO_1"

      assert [dor] = main.data_object_references
      assert dor.data_object_ref == "DO_1"
    end

    test "DOA with FEEL value_expression parses correctly", %{definitions: definitions} do
      [main | _] = definitions.processes

      st = Enum.find(main.flow_nodes, fn %FlowNode{id: id} -> id == "Task_2" end)
      assert [doa] = st.data_output_associations
      assert doa.id == "DOA_1"
      assert doa.target_ref == "DOR_1"
      assert doa.value_expression == "token.payment_result"
    end

    test "DIA parses source_ref correctly", %{definitions: definitions} do
      [main | _] = definitions.processes

      st = Enum.find(main.flow_nodes, fn %FlowNode{id: id} -> id == "Task_2" end)
      assert [dia] = st.data_input_associations
      assert dia.id == "DIA_1"
      assert dia.source_ref == "DOR_1"
    end

    test "evil:valueContract on DataObject parses JSON Schema", %{definitions: definitions} do
      [main | _] = definitions.processes
      assert [do_obj] = main.data_objects
      assert do_obj.value_contract == %{"type" => "object", "required" => ["status"]}
    end

    test "non-executable process is parsed", %{definitions: definitions} do
      helper = Enum.find(definitions.processes, &(&1.id == "Process_Helper"))
      refute helper.is_executable
    end
  end

  describe "parse/1 — CallActivity evil:startEventId" do
    test "parses startEventId extension element" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
                        xmlns:evil="https://evilengine.dev/schema/bpmn"
                        id="Defs_1">
        <bpmn:process id="P1" name="Test" isExecutable="true">
          <bpmn:extensionElements><evil:version>1.0.0</evil:version></bpmn:extensionElements>
          <bpmn:startEvent id="Start_1"><bpmn:outgoing>F1</bpmn:outgoing></bpmn:startEvent>
          <bpmn:callActivity id="CA_1" calledElement="child-proc">
            <bpmn:extensionElements>
              <evil:startEventId>Start_B</evil:startEventId>
            </bpmn:extensionElements>
            <bpmn:incoming>F1</bpmn:incoming>
            <bpmn:outgoing>F2</bpmn:outgoing>
          </bpmn:callActivity>
          <bpmn:endEvent id="End_1"><bpmn:incoming>F2</bpmn:incoming></bpmn:endEvent>
          <bpmn:sequenceFlow id="F1" sourceRef="Start_1" targetRef="CA_1"/>
          <bpmn:sequenceFlow id="F2" sourceRef="CA_1" targetRef="End_1"/>
        </bpmn:process>
      </bpmn:definitions>
      """

      assert {:ok, %Definitions{} = definitions} = Parser.parse(xml)
      [process] = definitions.processes

      call_activity = Enum.find(process.flow_nodes, &(&1.id == "CA_1"))
      assert %FlowNodeData.CallActivity{} = call_activity.type_data
      assert call_activity.type_data.called_element == "child-proc"
      assert call_activity.type_data.start_event_id == "Start_B"
    end

    test "startEventId defaults to nil when not specified" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
                        xmlns:evil="https://evilengine.dev/schema/bpmn"
                        id="Defs_1">
        <bpmn:process id="P1" name="Test" isExecutable="true">
          <bpmn:extensionElements><evil:version>1.0.0</evil:version></bpmn:extensionElements>
          <bpmn:startEvent id="Start_1"><bpmn:outgoing>F1</bpmn:outgoing></bpmn:startEvent>
          <bpmn:callActivity id="CA_1" calledElement="child-proc">
            <bpmn:incoming>F1</bpmn:incoming>
            <bpmn:outgoing>F2</bpmn:outgoing>
          </bpmn:callActivity>
          <bpmn:endEvent id="End_1"><bpmn:incoming>F2</bpmn:incoming></bpmn:endEvent>
          <bpmn:sequenceFlow id="F1" sourceRef="Start_1" targetRef="CA_1"/>
          <bpmn:sequenceFlow id="F2" sourceRef="CA_1" targetRef="End_1"/>
        </bpmn:process>
      </bpmn:definitions>
      """

      assert {:ok, %Definitions{}} = Parser.parse(xml)
      [process] = Parser.parse(xml) |> elem(1) |> Map.get(:processes)
      call_activity = Enum.find(process.flow_nodes, &(&1.id == "CA_1"))
      assert call_activity.type_data.start_event_id == nil
    end

    test "ignores empty startEventId" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
                        xmlns:evil="https://evilengine.dev/schema/bpmn"
                        id="Defs_1">
        <bpmn:process id="P1" name="Test" isExecutable="true">
          <bpmn:extensionElements><evil:version>1.0.0</evil:version></bpmn:extensionElements>
          <bpmn:startEvent id="Start_1"><bpmn:outgoing>F1</bpmn:outgoing></bpmn:startEvent>
          <bpmn:callActivity id="CA_1" calledElement="child-proc">
            <bpmn:extensionElements>
              <evil:startEventId>   </evil:startEventId>
            </bpmn:extensionElements>
            <bpmn:incoming>F1</bpmn:incoming>
            <bpmn:outgoing>F2</bpmn:outgoing>
          </bpmn:callActivity>
          <bpmn:endEvent id="End_1"><bpmn:incoming>F2</bpmn:incoming></bpmn:endEvent>
          <bpmn:sequenceFlow id="F1" sourceRef="Start_1" targetRef="CA_1"/>
          <bpmn:sequenceFlow id="F2" sourceRef="CA_1" targetRef="End_1"/>
        </bpmn:process>
      </bpmn:definitions>
      """

      assert {:ok, %Definitions{}} = Parser.parse(xml)
      [process] = Parser.parse(xml) |> elem(1) |> Map.get(:processes)
      call_activity = Enum.find(process.flow_nodes, &(&1.id == "CA_1"))
      assert call_activity.type_data.start_event_id == nil
    end
  end

  describe "parse/1 — direction-aware contracts on message events" do
    test "resultContract on intermediate catch event is parsed at flow-node level" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
                        xmlns:evil="https://evilengine.dev/schema/bpmn" id="D1">
        <bpmn:message id="Msg_1" name="test-msg"/>
        <bpmn:process id="P1" isExecutable="true">
          <bpmn:extensionElements><evil:version>1.0.0</evil:version></bpmn:extensionElements>
          <bpmn:startEvent id="Start_1"><bpmn:outgoing>F1</bpmn:outgoing></bpmn:startEvent>
          <bpmn:intermediateCatchEvent id="Catch_1">
            <bpmn:extensionElements>
              <evil:resultContract>{"type":"object","required":["orderId"]}</evil:resultContract>
            </bpmn:extensionElements>
            <bpmn:messageEventDefinition messageRef="Msg_1"/>
            <bpmn:incoming>F1</bpmn:incoming>
            <bpmn:outgoing>F2</bpmn:outgoing>
          </bpmn:intermediateCatchEvent>
          <bpmn:endEvent id="End_1"><bpmn:incoming>F2</bpmn:incoming></bpmn:endEvent>
          <bpmn:sequenceFlow id="F1" sourceRef="Start_1" targetRef="Catch_1"/>
          <bpmn:sequenceFlow id="F2" sourceRef="Catch_1" targetRef="End_1"/>
        </bpmn:process>
      </bpmn:definitions>
      """

      {:ok, definitions} = Parser.parse(xml)
      [process] = definitions.processes
      catch_node = Enum.find(process.flow_nodes, &(&1.id == "Catch_1"))

      assert %FlowNodeData.IntermediateCatchEvent{} = catch_node.type_data

      assert catch_node.type_data.result_contract == %{
               "type" => "object",
               "required" => ["orderId"]
             }

      assert %EventDefinition.Message{} = catch_node.type_data.event_definition
    end

    test "payloadContract on intermediate throw event is parsed at flow-node level" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
                        xmlns:evil="https://evilengine.dev/schema/bpmn" id="D1">
        <bpmn:message id="Msg_1" name="test-msg"/>
        <bpmn:process id="P1" isExecutable="true">
          <bpmn:extensionElements><evil:version>1.0.0</evil:version></bpmn:extensionElements>
          <bpmn:startEvent id="Start_1"><bpmn:outgoing>F1</bpmn:outgoing></bpmn:startEvent>
          <bpmn:intermediateThrowEvent id="Throw_1">
            <bpmn:extensionElements>
              <evil:payloadContract>{"type":"object","required":["amount"]}</evil:payloadContract>
            </bpmn:extensionElements>
            <bpmn:messageEventDefinition messageRef="Msg_1"/>
            <bpmn:incoming>F1</bpmn:incoming>
            <bpmn:outgoing>F2</bpmn:outgoing>
          </bpmn:intermediateThrowEvent>
          <bpmn:endEvent id="End_1"><bpmn:incoming>F2</bpmn:incoming></bpmn:endEvent>
          <bpmn:sequenceFlow id="F1" sourceRef="Start_1" targetRef="Throw_1"/>
          <bpmn:sequenceFlow id="F2" sourceRef="Throw_1" targetRef="End_1"/>
        </bpmn:process>
      </bpmn:definitions>
      """

      {:ok, definitions} = Parser.parse(xml)
      [process] = definitions.processes
      throw_node = Enum.find(process.flow_nodes, &(&1.id == "Throw_1"))

      assert %FlowNodeData.IntermediateThrowEvent{} = throw_node.type_data

      assert throw_node.type_data.payload_contract == %{
               "type" => "object",
               "required" => ["amount"]
             }
    end

    test "EventDefinition.Message no longer carries payload_contract" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
                        xmlns:evil="https://evilengine.dev/schema/bpmn" id="D1">
        <bpmn:message id="Msg_1" name="test-msg"/>
        <bpmn:process id="P1" isExecutable="true">
          <bpmn:extensionElements><evil:version>1.0.0</evil:version></bpmn:extensionElements>
          <bpmn:startEvent id="Start_1"><bpmn:outgoing>F1</bpmn:outgoing></bpmn:startEvent>
          <bpmn:intermediateCatchEvent id="Catch_1">
            <bpmn:messageEventDefinition messageRef="Msg_1">
              <bpmn:extensionElements>
                <evil:correlationRetrievalExpression>payload.id</evil:correlationRetrievalExpression>
              </bpmn:extensionElements>
            </bpmn:messageEventDefinition>
            <bpmn:incoming>F1</bpmn:incoming>
            <bpmn:outgoing>F2</bpmn:outgoing>
          </bpmn:intermediateCatchEvent>
          <bpmn:endEvent id="End_1"><bpmn:incoming>F2</bpmn:incoming></bpmn:endEvent>
          <bpmn:sequenceFlow id="F1" sourceRef="Start_1" targetRef="Catch_1"/>
          <bpmn:sequenceFlow id="F2" sourceRef="Catch_1" targetRef="End_1"/>
        </bpmn:process>
      </bpmn:definitions>
      """

      {:ok, definitions} = Parser.parse(xml)
      [process] = definitions.processes
      catch_node = Enum.find(process.flow_nodes, &(&1.id == "Catch_1"))

      assert %EventDefinition.Message{} = event_def = catch_node.type_data.event_definition
      refute Map.has_key?(event_def, :payload_contract)
    end

    test "resultContract on boundary event is parsed at flow-node level" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
                        xmlns:evil="https://evilengine.dev/schema/bpmn" id="D1">
        <bpmn:message id="Msg_1" name="test-msg"/>
        <bpmn:process id="P1" isExecutable="true">
          <bpmn:extensionElements><evil:version>1.0.0</evil:version></bpmn:extensionElements>
          <bpmn:startEvent id="Start_1"><bpmn:outgoing>F1</bpmn:outgoing></bpmn:startEvent>
          <bpmn:userTask id="Task_1">
            <bpmn:incoming>F1</bpmn:incoming>
            <bpmn:outgoing>F2</bpmn:outgoing>
          </bpmn:userTask>
          <bpmn:boundaryEvent id="Boundary_1" attachedToRef="Task_1" cancelActivity="true">
            <bpmn:extensionElements>
              <evil:resultContract>{"type":"object","required":["status"]}</evil:resultContract>
            </bpmn:extensionElements>
            <bpmn:messageEventDefinition messageRef="Msg_1"/>
            <bpmn:outgoing>F3</bpmn:outgoing>
          </bpmn:boundaryEvent>
          <bpmn:endEvent id="End_1"><bpmn:incoming>F2</bpmn:incoming></bpmn:endEvent>
          <bpmn:endEvent id="End_2"><bpmn:incoming>F3</bpmn:incoming></bpmn:endEvent>
          <bpmn:sequenceFlow id="F1" sourceRef="Start_1" targetRef="Task_1"/>
          <bpmn:sequenceFlow id="F2" sourceRef="Task_1" targetRef="End_1"/>
          <bpmn:sequenceFlow id="F3" sourceRef="Boundary_1" targetRef="End_2"/>
        </bpmn:process>
      </bpmn:definitions>
      """

      {:ok, definitions} = Parser.parse(xml)
      [process] = definitions.processes
      boundary_node = Enum.find(process.flow_nodes, &(&1.id == "Boundary_1"))

      assert %FlowNodeData.BoundaryEvent{} = boundary_node.type_data

      assert boundary_node.type_data.result_contract == %{
               "type" => "object",
               "required" => ["status"]
             }
    end

    test "payloadContract on end event is parsed at flow-node level" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
                        xmlns:evil="https://evilengine.dev/schema/bpmn" id="D1">
        <bpmn:message id="Msg_1" name="test-msg"/>
        <bpmn:process id="P1" isExecutable="true">
          <bpmn:extensionElements><evil:version>1.0.0</evil:version></bpmn:extensionElements>
          <bpmn:startEvent id="Start_1"><bpmn:outgoing>F1</bpmn:outgoing></bpmn:startEvent>
          <bpmn:endEvent id="End_1">
            <bpmn:extensionElements>
              <evil:payloadContract>{"type":"object","required":["total"]}</evil:payloadContract>
            </bpmn:extensionElements>
            <bpmn:messageEventDefinition messageRef="Msg_1"/>
            <bpmn:incoming>F1</bpmn:incoming>
          </bpmn:endEvent>
          <bpmn:sequenceFlow id="F1" sourceRef="Start_1" targetRef="End_1"/>
        </bpmn:process>
      </bpmn:definitions>
      """

      {:ok, definitions} = Parser.parse(xml)
      [process] = definitions.processes
      end_node = Enum.find(process.flow_nodes, &(&1.id == "End_1"))

      assert %FlowNodeData.EndEvent{} = end_node.type_data
      assert end_node.type_data.payload_contract == %{"type" => "object", "required" => ["total"]}
    end

    test "resultContract on start event is parsed at flow-node level" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
                        xmlns:evil="https://evilengine.dev/schema/bpmn" id="D1">
        <bpmn:message id="Msg_1" name="test-msg"/>
        <bpmn:process id="P1" isExecutable="true">
          <bpmn:extensionElements><evil:version>1.0.0</evil:version></bpmn:extensionElements>
          <bpmn:startEvent id="Start_1">
            <bpmn:extensionElements>
              <evil:resultContract>{"type":"object","required":["customerId"]}</evil:resultContract>
            </bpmn:extensionElements>
            <bpmn:messageEventDefinition messageRef="Msg_1"/>
            <bpmn:outgoing>F1</bpmn:outgoing>
          </bpmn:startEvent>
          <bpmn:endEvent id="End_1"><bpmn:incoming>F1</bpmn:incoming></bpmn:endEvent>
          <bpmn:sequenceFlow id="F1" sourceRef="Start_1" targetRef="End_1"/>
        </bpmn:process>
      </bpmn:definitions>
      """

      {:ok, definitions} = Parser.parse(xml)
      [process] = definitions.processes
      start_node = Enum.find(process.flow_nodes, &(&1.id == "Start_1"))

      assert %FlowNodeData.StartEvent{} = start_node.type_data

      assert start_node.type_data.result_contract == %{
               "type" => "object",
               "required" => ["customerId"]
             }
    end
  end

  describe "parse/1 — error cases" do
    test "malformed XML returns error with parse details" do
      assert {:error, reason} = Parser.parse("<not valid xml>>>>>")
      assert reason != nil
    end

    test "non-binary input returns error" do
      assert {:error, :invalid_input} = Parser.parse(123)
    end

    test "empty string returns error with parse details" do
      assert {:error, reason} = Parser.parse("")
      assert reason != nil
    end
  end

  describe "parse/1 — embedded subprocess" do
    @subprocess_xml """
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

    test "parses subprocess as a flow node with nested children" do
      assert {:ok, %Definitions{} = definitions} = Parser.parse(@subprocess_xml)
      [process] = definitions.processes

      parent_types = Enum.map(process.flow_nodes, & &1.type) |> Enum.sort()
      assert parent_types == [:end_event, :start_event, :sub_process]

      subprocess = Enum.find(process.flow_nodes, &(&1.type == :sub_process))
      assert subprocess.id == "SubProcess_1"
      assert subprocess.name == "Embedded"

      %FlowNodeData.SubProcess{} = subprocess.type_data
      assert length(subprocess.type_data.flow_nodes) == 3
      assert length(subprocess.type_data.sequence_flows) == 2

      child_types = Enum.map(subprocess.type_data.flow_nodes, & &1.type) |> Enum.sort()
      assert child_types == [:end_event, :start_event, :task]
    end

    test "subprocess children are not added to parent process" do
      {:ok, definitions} = Parser.parse(@subprocess_xml)
      [process] = definitions.processes

      parent_ids = Enum.map(process.flow_nodes, & &1.id) |> MapSet.new()
      refute MapSet.member?(parent_ids, "Sub_Start_1")
      refute MapSet.member?(parent_ids, "Sub_Task_1")
      refute MapSet.member?(parent_ids, "Sub_End_1")

      parent_flow_ids = Enum.map(process.sequence_flows, & &1.id) |> MapSet.new()
      refute MapSet.member?(parent_flow_ids, "Sub_Flow_1")
      refute MapSet.member?(parent_flow_ids, "Sub_Flow_2")
    end

    test "parent sequence flows are preserved correctly" do
      {:ok, definitions} = Parser.parse(@subprocess_xml)
      [process] = definitions.processes

      assert length(process.sequence_flows) == 2
      flow_ids = Enum.map(process.sequence_flows, & &1.id) |> MapSet.new()
      assert MapSet.member?(flow_ids, "Flow_1")
      assert MapSet.member?(flow_ids, "Flow_2")
    end

    test "event subprocess sets triggered_by_event flag" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
                        xmlns:evil="https://evilengine.dev/schema/bpmn"
                        id="Definitions_1">
        <bpmn:process id="Process_1" isExecutable="true">
          <bpmn:extensionElements>
            <evil:version>1.0.0</evil:version>
          </bpmn:extensionElements>
          <bpmn:subProcess id="EventSub_1" triggeredByEvent="true">
            <bpmn:startEvent id="ESub_Start_1" />
          </bpmn:subProcess>
        </bpmn:process>
      </bpmn:definitions>
      """

      {:ok, definitions} = Parser.parse(xml)
      [process] = definitions.processes

      event_sub = Enum.find(process.flow_nodes, &(&1.id == "EventSub_1"))
      assert event_sub.type_data.triggered_by_event == true
    end

    test "ESP start event defaults is_interrupting to true when isInterrupting absent" do
      xml = esp_start_xml(~s(<bpmn:messageEventDefinition id="D" messageRef="M" />), "")

      {:ok, definitions} = Parser.parse(xml)
      assert esp_start_event(definitions).type_data.is_interrupting == true
    end

    test "ESP start event with isInterrupting=\"true\" parses as interrupting" do
      xml =
        esp_start_xml(~s(<bpmn:messageEventDefinition id="D" messageRef="M" />), ~s(isInterrupting="true"))

      {:ok, definitions} = Parser.parse(xml)
      assert esp_start_event(definitions).type_data.is_interrupting == true
    end

    test "ESP start event with isInterrupting=\"false\" parses as non-interrupting" do
      xml =
        esp_start_xml(~s(<bpmn:messageEventDefinition id="D" messageRef="M" />), ~s(isInterrupting="false"))

      {:ok, definitions} = Parser.parse(xml)
      assert esp_start_event(definitions).type_data.is_interrupting == false
    end

    test "ESP message start event definition parses" do
      xml = esp_start_xml(~s(<bpmn:messageEventDefinition id="D" messageRef="M" />), "")
      {:ok, definitions} = Parser.parse(xml)
      assert %EventDefinition.Message{} = esp_start_event(definitions).type_data.event_definition
    end

    test "ESP signal start event definition parses" do
      xml = esp_start_xml(~s(<bpmn:signalEventDefinition id="D" signalRef="S" />), "")
      {:ok, definitions} = Parser.parse(xml)
      assert %EventDefinition.Signal{} = esp_start_event(definitions).type_data.event_definition
    end

    test "ESP timer start event definition parses" do
      xml =
        esp_start_xml(
          ~s(<bpmn:timerEventDefinition id="D"><bpmn:timeDuration>PT5M</bpmn:timeDuration></bpmn:timerEventDefinition>),
          ""
        )

      {:ok, definitions} = Parser.parse(xml)
      assert %EventDefinition.Timer{} = esp_start_event(definitions).type_data.event_definition
    end

    test "ESP error start event definition parses" do
      xml =
        esp_start_xml(~s(<bpmn:errorEventDefinition id="D" errorRef="E" />), ~s(isInterrupting="true"))

      {:ok, definitions} = Parser.parse(xml)
      assert %EventDefinition.Error{} = esp_start_event(definitions).type_data.event_definition
    end

    test "ESP escalation start event definition parses" do
      xml = esp_start_xml(~s(<bpmn:escalationEventDefinition id="D" escalationRef="ESC" />), "")
      {:ok, definitions} = Parser.parse(xml)

      assert %EventDefinition.Escalation{} =
               esp_start_event(definitions).type_data.event_definition
    end

    test "ESP conditional start event definition parses" do
      xml =
        esp_start_xml(
          ~s(<bpmn:conditionalEventDefinition id="D"><bpmn:condition>token.ready = true</bpmn:condition></bpmn:conditionalEventDefinition>),
          ""
        )

      {:ok, definitions} = Parser.parse(xml)

      assert %EventDefinition.Conditional{} =
               esp_start_event(definitions).type_data.event_definition
    end

    test "nested event subprocess parses inner ESP with its own trigger" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
                        xmlns:evil="https://evilengine.dev/schema/bpmn"
                        id="Definitions_1">
        <bpmn:process id="Process_1" isExecutable="true">
          <bpmn:extensionElements>
            <evil:version>1.0.0</evil:version>
          </bpmn:extensionElements>
          <bpmn:subProcess id="ESP_Outer" triggeredByEvent="true">
            <bpmn:startEvent id="ESP_Outer_Start">
              <bpmn:messageEventDefinition id="D1" messageRef="M" />
            </bpmn:startEvent>
            <bpmn:subProcess id="ESP_Inner" triggeredByEvent="true">
              <bpmn:startEvent id="ESP_Inner_Start" isInterrupting="false">
                <bpmn:signalEventDefinition id="D2" signalRef="S" />
              </bpmn:startEvent>
            </bpmn:subProcess>
          </bpmn:subProcess>
        </bpmn:process>
      </bpmn:definitions>
      """

      {:ok, definitions} = Parser.parse(xml)
      [process] = definitions.processes

      outer = Enum.find(process.flow_nodes, &(&1.id == "ESP_Outer"))
      assert outer.type_data.triggered_by_event == true

      inner = Enum.find(outer.type_data.flow_nodes, &(&1.id == "ESP_Inner"))
      assert inner.type_data.triggered_by_event == true

      inner_start = Enum.find(inner.type_data.flow_nodes, &(&1.id == "ESP_Inner_Start"))
      assert inner_start.type_data.is_interrupting == false
      assert %EventDefinition.Signal{} = inner_start.type_data.event_definition
    end

    test "subprocess shell has incoming and outgoing refs" do
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
          <bpmn:subProcess id="SubProcess_1" name="Embedded">
            <bpmn:incoming>Flow_1</bpmn:incoming>
            <bpmn:outgoing>Flow_2</bpmn:outgoing>
            <bpmn:startEvent id="Sub_Start_1">
              <bpmn:outgoing>Sub_Flow_1</bpmn:outgoing>
            </bpmn:startEvent>
            <bpmn:endEvent id="Sub_End_1">
              <bpmn:incoming>Sub_Flow_1</bpmn:incoming>
            </bpmn:endEvent>
            <bpmn:sequenceFlow id="Sub_Flow_1" sourceRef="Sub_Start_1" targetRef="Sub_End_1" />
          </bpmn:subProcess>
          <bpmn:endEvent id="End_1">
            <bpmn:incoming>Flow_2</bpmn:incoming>
          </bpmn:endEvent>
          <bpmn:sequenceFlow id="Flow_1" sourceRef="Start_1" targetRef="SubProcess_1" />
          <bpmn:sequenceFlow id="Flow_2" sourceRef="SubProcess_1" targetRef="End_1" />
        </bpmn:process>
      </bpmn:definitions>
      """

      {:ok, definitions} = Parser.parse(xml)
      [process] = definitions.processes
      subprocess = Enum.find(process.flow_nodes, &(&1.id == "SubProcess_1"))

      assert MapSet.new(subprocess.incoming) == MapSet.new(["Flow_1"])
      assert MapSet.new(subprocess.outgoing) == MapSet.new(["Flow_2"])
    end

    test "subprocess shell captures evil:inputMapping and evil:outputMapping" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
                        xmlns:evil="https://evilengine.dev/schema/bpmn"
                        id="Definitions_1">
        <bpmn:process id="Process_1" isExecutable="true">
          <bpmn:extensionElements>
            <evil:version>1.0.0</evil:version>
          </bpmn:extensionElements>
          <bpmn:subProcess id="SubProcess_1">
            <bpmn:extensionElements>
              <evil:inputMapping source="token.orderId" target="orderId" />
              <evil:outputMapping source="result.status" target="status" />
            </bpmn:extensionElements>
            <bpmn:startEvent id="Sub_Start_1" />
          </bpmn:subProcess>
        </bpmn:process>
      </bpmn:definitions>
      """

      {:ok, definitions} = Parser.parse(xml)
      [process] = definitions.processes
      subprocess = Enum.find(process.flow_nodes, &(&1.id == "SubProcess_1"))

      assert %FlowNodeData.SubProcess{
               in_mappings: [%Mapping{source: "token.orderId", target: "orderId"}],
               out_mappings: [%Mapping{source: "result.status", target: "status"}]
             } = subprocess.type_data
    end

    test "subprocess shell captures evil:payloadContract and evil:resultContract" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
                        xmlns:evil="https://evilengine.dev/schema/bpmn"
                        id="Definitions_1">
        <bpmn:process id="Process_1" isExecutable="true">
          <bpmn:extensionElements>
            <evil:version>1.0.0</evil:version>
          </bpmn:extensionElements>
          <bpmn:subProcess id="SubProcess_1">
            <bpmn:extensionElements>
              <evil:payloadContract>{"type":"object","required":["orderId"]}</evil:payloadContract>
              <evil:resultContract>{"type":"object","required":["status"]}</evil:resultContract>
            </bpmn:extensionElements>
            <bpmn:startEvent id="Sub_Start_1" />
          </bpmn:subProcess>
        </bpmn:process>
      </bpmn:definitions>
      """

      {:ok, definitions} = Parser.parse(xml)
      [process] = definitions.processes
      subprocess = Enum.find(process.flow_nodes, &(&1.id == "SubProcess_1"))

      assert %FlowNodeData.SubProcess{
               payload_contract: %{"type" => "object", "required" => ["orderId"]},
               result_contract: %{"type" => "object", "required" => ["status"]}
             } = subprocess.type_data
    end

    test "inner gateway default flows are applied within subprocess" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
                        xmlns:evil="https://evilengine.dev/schema/bpmn"
                        id="Definitions_1">
        <bpmn:process id="Process_1" isExecutable="true">
          <bpmn:extensionElements>
            <evil:version>1.0.0</evil:version>
          </bpmn:extensionElements>
          <bpmn:subProcess id="SubProcess_1">
            <bpmn:startEvent id="Sub_Start_1">
              <bpmn:outgoing>Sub_Flow_1</bpmn:outgoing>
            </bpmn:startEvent>
            <bpmn:exclusiveGateway id="Sub_GW_1" default="Sub_Flow_default">
              <bpmn:incoming>Sub_Flow_1</bpmn:incoming>
              <bpmn:outgoing>Sub_Flow_yes</bpmn:outgoing>
              <bpmn:outgoing>Sub_Flow_default</bpmn:outgoing>
            </bpmn:exclusiveGateway>
            <bpmn:endEvent id="Sub_End_1">
              <bpmn:incoming>Sub_Flow_yes</bpmn:incoming>
            </bpmn:endEvent>
            <bpmn:endEvent id="Sub_End_2">
              <bpmn:incoming>Sub_Flow_default</bpmn:incoming>
            </bpmn:endEvent>
            <bpmn:sequenceFlow id="Sub_Flow_1" sourceRef="Sub_Start_1" targetRef="Sub_GW_1" />
            <bpmn:sequenceFlow id="Sub_Flow_yes" sourceRef="Sub_GW_1" targetRef="Sub_End_1" />
            <bpmn:sequenceFlow id="Sub_Flow_default" sourceRef="Sub_GW_1" targetRef="Sub_End_2" />
          </bpmn:subProcess>
        </bpmn:process>
      </bpmn:definitions>
      """

      {:ok, definitions} = Parser.parse(xml)
      [process] = definitions.processes
      subprocess = Enum.find(process.flow_nodes, &(&1.id == "SubProcess_1"))
      gateway = Enum.find(subprocess.type_data.flow_nodes, &(&1.id == "Sub_GW_1"))

      assert %FlowNodeData.ExclusiveGateway{default_flow_ref: "Sub_Flow_default"} =
               gateway.type_data

      default_flow =
        Enum.find(subprocess.type_data.sequence_flows, &(&1.id == "Sub_Flow_default"))

      assert default_flow.is_default == true
    end

    test "inner boundary events are linked within subprocess" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
                        xmlns:evil="https://evilengine.dev/schema/bpmn"
                        id="Definitions_1">
        <bpmn:process id="Process_1" isExecutable="true">
          <bpmn:extensionElements>
            <evil:version>1.0.0</evil:version>
          </bpmn:extensionElements>
          <bpmn:subProcess id="SubProcess_1">
            <bpmn:startEvent id="Sub_Start_1">
              <bpmn:outgoing>Sub_Flow_1</bpmn:outgoing>
            </bpmn:startEvent>
            <bpmn:task id="Sub_Task_1">
              <bpmn:incoming>Sub_Flow_1</bpmn:incoming>
              <bpmn:outgoing>Sub_Flow_2</bpmn:outgoing>
            </bpmn:task>
            <bpmn:boundaryEvent id="Sub_Boundary_1" attachedToRef="Sub_Task_1">
              <bpmn:timerEventDefinition />
            </bpmn:boundaryEvent>
            <bpmn:endEvent id="Sub_End_1">
              <bpmn:incoming>Sub_Flow_2</bpmn:incoming>
            </bpmn:endEvent>
            <bpmn:sequenceFlow id="Sub_Flow_1" sourceRef="Sub_Start_1" targetRef="Sub_Task_1" />
            <bpmn:sequenceFlow id="Sub_Flow_2" sourceRef="Sub_Task_1" targetRef="Sub_End_1" />
          </bpmn:subProcess>
        </bpmn:process>
      </bpmn:definitions>
      """

      {:ok, definitions} = Parser.parse(xml)
      [process] = definitions.processes
      subprocess = Enum.find(process.flow_nodes, &(&1.id == "SubProcess_1"))
      host_task = Enum.find(subprocess.type_data.flow_nodes, &(&1.id == "Sub_Task_1"))

      assert host_task.boundary_event_refs == ["Sub_Boundary_1"]
    end

    test "nested subprocess parses correctly" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
                        xmlns:evil="https://evilengine.dev/schema/bpmn"
                        id="Definitions_1">
        <bpmn:process id="Process_1" isExecutable="true">
          <bpmn:extensionElements>
            <evil:version>1.0.0</evil:version>
          </bpmn:extensionElements>
          <bpmn:subProcess id="Outer_SubProcess">
            <bpmn:subProcess id="Inner_SubProcess">
              <bpmn:startEvent id="Inner_Start_1">
                <bpmn:outgoing>Inner_Flow_1</bpmn:outgoing>
              </bpmn:startEvent>
              <bpmn:task id="Inner_Task_1">
                <bpmn:incoming>Inner_Flow_1</bpmn:incoming>
                <bpmn:outgoing>Inner_Flow_2</bpmn:outgoing>
              </bpmn:task>
              <bpmn:endEvent id="Inner_End_1">
                <bpmn:incoming>Inner_Flow_2</bpmn:incoming>
              </bpmn:endEvent>
              <bpmn:sequenceFlow id="Inner_Flow_1" sourceRef="Inner_Start_1" targetRef="Inner_Task_1" />
              <bpmn:sequenceFlow id="Inner_Flow_2" sourceRef="Inner_Task_1" targetRef="Inner_End_1" />
            </bpmn:subProcess>
            <bpmn:startEvent id="Outer_Start_1" />
          </bpmn:subProcess>
        </bpmn:process>
      </bpmn:definitions>
      """

      {:ok, definitions} = Parser.parse(xml)
      [process] = definitions.processes
      outer = Enum.find(process.flow_nodes, &(&1.id == "Outer_SubProcess"))
      inner = Enum.find(outer.type_data.flow_nodes, &(&1.id == "Inner_SubProcess"))

      assert inner.type == :sub_process
      assert length(inner.type_data.flow_nodes) == 3
      assert length(inner.type_data.sequence_flows) == 2

      inner_types = Enum.map(inner.type_data.flow_nodes, & &1.type) |> Enum.sort()
      assert inner_types == [:end_event, :start_event, :task]

      outer_types = Enum.map(outer.type_data.flow_nodes, & &1.type) |> Enum.sort()
      assert outer_types == [:start_event, :sub_process]
    end

    test "data objects inside subprocess are scoped to subprocess, not parent" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
                        xmlns:evil="https://evilengine.dev/schema/bpmn"
                        id="Definitions_1">
        <bpmn:process id="Process_1" isExecutable="true">
          <bpmn:extensionElements>
            <evil:version>1.0.0</evil:version>
          </bpmn:extensionElements>
          <bpmn:dataObject id="DO_Parent" name="ParentData" />
          <bpmn:dataObjectReference id="DOR_Parent" name="ParentDataRef" dataObjectRef="DO_Parent" />
          <bpmn:subProcess id="SubProcess_1">
            <bpmn:dataObject id="DO_Inner" name="InnerData" />
            <bpmn:dataObjectReference id="DOR_Inner" name="InnerDataRef" dataObjectRef="DO_Inner" />
            <bpmn:startEvent id="Sub_Start_1" />
          </bpmn:subProcess>
        </bpmn:process>
      </bpmn:definitions>
      """

      {:ok, definitions} = Parser.parse(xml)
      [process] = definitions.processes

      assert [parent_do] = process.data_objects
      assert parent_do.id == "DO_Parent"

      assert [parent_dor] = process.data_object_references
      assert parent_dor.id == "DOR_Parent"

      subprocess = Enum.find(process.flow_nodes, &(&1.id == "SubProcess_1"))
      assert [inner_do] = subprocess.type_data.data_objects
      assert inner_do.id == "DO_Inner"

      assert [inner_dor] = subprocess.type_data.data_object_references
      assert inner_dor.id == "DOR_Inner"
    end

    test "nested subprocess data objects are isolated per scope level" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
                        xmlns:evil="https://evilengine.dev/schema/bpmn"
                        id="Definitions_1">
        <bpmn:process id="Process_1" isExecutable="true">
          <bpmn:extensionElements>
            <evil:version>1.0.0</evil:version>
          </bpmn:extensionElements>
          <bpmn:dataObject id="DO_Root" name="RootData" />
          <bpmn:subProcess id="Outer_SubProcess">
            <bpmn:dataObject id="DO_Outer" name="OuterData" />
            <bpmn:subProcess id="Inner_SubProcess">
              <bpmn:dataObject id="DO_Inner" name="InnerData" />
              <bpmn:startEvent id="Inner_Start_1" />
            </bpmn:subProcess>
            <bpmn:startEvent id="Outer_Start_1" />
          </bpmn:subProcess>
        </bpmn:process>
      </bpmn:definitions>
      """

      {:ok, definitions} = Parser.parse(xml)
      [process] = definitions.processes

      assert [root_do] = process.data_objects
      assert root_do.id == "DO_Root"

      outer = Enum.find(process.flow_nodes, &(&1.id == "Outer_SubProcess"))
      assert [outer_do] = outer.type_data.data_objects
      assert outer_do.id == "DO_Outer"

      inner = Enum.find(outer.type_data.flow_nodes, &(&1.id == "Inner_SubProcess"))
      assert [inner_do] = inner.type_data.data_objects
      assert inner_do.id == "DO_Inner"
    end
  end

  describe "parse/1 — parser_coverage_signals.bpmn" do
    setup do
      {:ok, definitions} = Parser.parse(read_fixture("parser_coverage_signals.bpmn"))
      [process] = definitions.processes
      %{definitions: definitions, process: process}
    end

    test "parses global SignalDefinition from signal id and name attributes", %{
      definitions: definitions
    } do
      assert [%SignalDefinition{} = signal] = definitions.signals
      assert signal.id == "Signal_Done"
      assert signal.name == "order-done"
    end

    test "parses seven flow nodes with expected types", %{process: process} do
      assert length(process.flow_nodes) == 7

      types = Enum.map(process.flow_nodes, & &1.type) |> Enum.sort()

      assert types == [
               :boundary_event,
               :end_event,
               :end_event,
               :intermediate_catch_event,
               :intermediate_throw_event,
               :start_event,
               :user_task
             ]
    end

    test "signal start event maps signalRef attribute to event_definition.signal_ref", %{
      process: process
    } do
      start = find_node(process, "Start_Signal")

      assert %FlowNodeData.StartEvent{
               event_definition: %EventDefinition.Signal{signal_ref: "Signal_Done"}
             } = start.type_data

      refute Map.has_key?(start.type_data.event_definition, :name)
    end

    test "signal intermediate catch maps signalRef to signal_ref", %{process: process} do
      catch_event = find_node(process, "Catch_Signal")

      assert %FlowNodeData.IntermediateCatchEvent{
               event_definition: %EventDefinition.Signal{signal_ref: "Signal_Done"}
             } = catch_event.type_data
    end

    test "signal intermediate throw maps signalRef to signal_ref", %{process: process} do
      throw_event = find_node(process, "Throw_Signal")

      assert %FlowNodeData.IntermediateThrowEvent{
               event_definition: %EventDefinition.Signal{signal_ref: "Signal_Done"}
             } = throw_event.type_data
    end

    test "signal end event maps signalRef to signal_ref", %{process: process} do
      end_event = find_node(process, "End_Signal")

      assert %FlowNodeData.EndEvent{
               event_definition: %EventDefinition.Signal{signal_ref: "Signal_Done"}
             } = end_event.type_data
    end

    test "signal name stays on SignalDefinition not EventDefinition.Signal", %{
      definitions: definitions,
      process: process
    } do
      [%SignalDefinition{name: "order-done"}] = definitions.signals

      boundary = find_node(process, "Boundary_Signal")

      assert %EventDefinition.Signal{signal_ref: "Signal_Done"} =
               boundary.type_data.event_definition

      refute Map.has_key?(boundary.type_data.event_definition, :name)
    end

    test "non-interrupting signal boundary maps attachedToRef and cancelActivity", %{
      process: process
    } do
      boundary = find_node(process, "Boundary_Signal")

      assert %FlowNodeData.BoundaryEvent{
               attached_to_ref: "UserTask_Host",
               cancel_activity: false,
               event_definition: %EventDefinition.Signal{signal_ref: "Signal_Done"}
             } = boundary.type_data
    end

    test "host user task links boundary via boundary_event_refs", %{process: process} do
      host = find_node(process, "UserTask_Host")
      assert host.boundary_event_refs == ["Boundary_Signal"]
    end
  end

  describe "parse/1 — parser_coverage_escalation_compensation.bpmn" do
    setup do
      {:ok, definitions} =
        Parser.parse(read_fixture("parser_coverage_escalation_compensation.bpmn"))

      [process] = definitions.processes
      %{definitions: definitions, process: process}
    end

    test "parses global EscalationDefinition from escalationCode attribute", %{
      definitions: definitions
    } do
      assert [%EscalationDefinition{} = escalation] = definitions.escalations
      assert escalation.id == "Esc_1"
      assert escalation.name == "Level2"
      assert escalation.escalation_code == "ESC_LVL2"
    end

    test "parses thirteen flow nodes including boundary, compensation, and end events", %{
      process: process
    } do
      assert length(process.flow_nodes) == 13
    end

    test "escalation end event maps escalationRef to escalation_ref", %{process: process} do
      end_event = find_node(process, "End_Escalation")

      assert %FlowNodeData.EndEvent{
               event_definition: %EventDefinition.Escalation{escalation_ref: "Esc_1"}
             } = end_event.type_data

      refute end_event.type_data.event_definition.escalation_code
    end

    test "interrupting escalation boundary maps escalationRef and attachedToRef", %{
      process: process
    } do
      boundary = find_node(process, "Boundary_Escalation")

      assert %FlowNodeData.BoundaryEvent{
               attached_to_ref: "Task_EscalationHost",
               cancel_activity: true,
               event_definition: %EventDefinition.Escalation{escalation_ref: "Esc_1"}
             } = boundary.type_data
    end

    test "compensation end maps activityRef to activity_ref", %{process: process} do
      end_event = find_node(process, "End_Compensation")

      assert %FlowNodeData.EndEvent{
               event_definition: %EventDefinition.Compensation{
                 activity_ref: "Task_Compensate",
                 wait_for_completion: true
               }
             } = end_event.type_data
    end

    test "compensation boundary resolves handler via association", %{process: process} do
      boundary = find_node(process, "Boundary_Compensation")

      assert %FlowNodeData.BoundaryEvent{
               event_definition: %EventDefinition.Compensation{},
               compensation_handler_id: "Task_CompHandler"
             } = boundary.type_data
    end

    test "isForCompensation flag is parsed on handler activity", %{process: process} do
      handler = find_node(process, "Task_CompHandler")

      assert handler.is_for_compensation
    end

    test "association is parsed into process associations list", %{process: process} do
      assert [association] = process.associations
      assert association.id == "Association_Comp"
      assert association.source_ref == "Boundary_Compensation"
      assert association.target_ref == "Task_CompHandler"
      assert association.association_direction == "One"
    end

    test "compensate intermediate throw maps activityRef to activity_ref", %{process: process} do
      throw_event = find_node(process, "Throw_Compensation")

      assert %FlowNodeData.IntermediateThrowEvent{
               event_definition: %EventDefinition.Compensation{
                 activity_ref: "Task_Compensate"
               }
             } = throw_event.type_data
    end

    test "non-compensation activities have is_for_compensation false", %{process: process} do
      task = find_node(process, "Task_Compensate")

      refute task.is_for_compensation
    end

    test "cancel end event carries empty EventDefinition.Cancel", %{process: process} do
      end_event = find_node(process, "End_Cancel")

      assert %FlowNodeData.EndEvent{event_definition: %EventDefinition.Cancel{}} =
               end_event.type_data
    end

    test "conditional boundary maps condition child text to condition_expression", %{
      process: process
    } do
      boundary = find_node(process, "Boundary_Conditional")

      assert %FlowNodeData.BoundaryEvent{
               attached_to_ref: "Task_ConditionalHost",
               cancel_activity: false,
               event_definition: %EventDefinition.Conditional{
                 condition_expression: "token.amount > 1000"
               }
             } = boundary.type_data
    end

    test "escalation_code stays on EscalationDefinition not EventDefinition.Escalation", %{
      definitions: definitions,
      process: process
    } do
      [%EscalationDefinition{escalation_code: "ESC_LVL2"}] = definitions.escalations

      boundary = find_node(process, "Boundary_Escalation")
      refute boundary.type_data.event_definition.escalation_code
    end
  end

  describe "parse/1 — parser_coverage_tasks_gateways.bpmn" do
    setup do
      {:ok, definitions} = Parser.parse(read_fixture("parser_coverage_tasks_gateways.bpmn"))
      [process] = definitions.processes
      %{definitions: definitions, process: process}
    end

    test "parses collaboration without crashing and extracts one process", %{
      definitions: definitions
    } do
      assert length(definitions.processes) == 1

      assert {:ok, %Definitions{}} =
               Parser.parse(read_fixture("parser_coverage_tasks_gateways.bpmn"))
    end

    test "parses eight flow nodes with task and gateway types", %{process: process} do
      assert length(process.flow_nodes) == 8

      types = Enum.map(process.flow_nodes, & &1.type) |> Enum.sort()

      assert types == [
               :call_activity,
               :complex_gateway,
               :end_event,
               :event_based_gateway,
               :manual_task,
               :receive_task,
               :send_task,
               :start_event
             ]
    end

    test "manual task maps evil:requireConfirmation text to require_confirmation", %{
      process: process
    } do
      manual_task = find_node(process, "MT_1")

      assert %FlowNodeData.ManualTask{require_confirmation: true} = manual_task.type_data
      assert manual_task.documentation == "Some docs"
    end

    test "send task maps messageRef attribute to message_ref", %{process: process} do
      send_task = find_node(process, "ST_1")

      assert %FlowNodeData.SendTask{message_ref: "Msg_Send"} = send_task.type_data
      refute Map.has_key?(send_task.type_data, :messageRef)
    end

    test "receive task maps messageRef attribute to message_ref", %{process: process} do
      receive_task = find_node(process, "RT_1")

      assert %FlowNodeData.ReceiveTask{message_ref: "Msg_Receive"} = receive_task.type_data
    end

    test "parses global message definitions for send and receive tasks", %{
      definitions: definitions
    } do
      message_ids = definitions.messages |> Enum.map(& &1.id) |> Enum.sort()
      assert message_ids == ["Msg_Receive", "Msg_Send"]
    end

    test "event based gateway has empty type_data struct", %{process: process} do
      gateway = find_node(process, "EBG_1")

      assert gateway.type == :event_based_gateway
      assert %FlowNodeData.EventBasedGateway{} = gateway.type_data
    end

    test "complex gateway maps activationCondition child text to activation_condition", %{
      process: process
    } do
      gateway = find_node(process, "CG_1")

      assert %FlowNodeData.ComplexGateway{
               activation_condition: "activatedCount >= 2"
             } = gateway.type_data
    end

    test "definitions-level evil:LinterRulesetScore maps all Studio attributes", %{
      definitions: definitions
    } do
      assert [%LinterRulesetScore{} = score] = definitions.linter_scores
      assert score.ruleset_id == "evil-default"
      assert score.score_percent == 92.5
      assert score.compliance_status == "valid"
      assert score.computed_at_iso == "2026-07-03T12:00:00Z"
      assert score.schema_version == "1"
      assert score.max_points == 100.0
      assert score.penalty_points == 7.5
      assert score.raw_error_findings == 0
      assert score.raw_warning_findings == 2
    end

    test "call activity maps inputMapping and outputMapping attributes to Mapping structs", %{
      process: process
    } do
      call_activity = find_node(process, "CA_1")

      assert %FlowNodeData.CallActivity{
               called_element: "child-process",
               in_mappings: [%Mapping{source: "token.orderId", target: "orderId"}],
               out_mappings: [%Mapping{source: "result.trackingNumber", target: "trackingNumber"}]
             } = call_activity.type_data
    end
  end

  describe "parse/1 — parser_coverage_multi_instance.bpmn" do
    setup do
      {:ok, definitions} = Parser.parse(read_fixture("parser_coverage_multi_instance.bpmn"))
      [process] = definitions.processes
      %{process: process}
    end

    test "parses five flow nodes including link throw and catch", %{process: process} do
      assert length(process.flow_nodes) == 5

      types = Enum.map(process.flow_nodes, & &1.type) |> Enum.sort()

      assert types == [
               :end_event,
               :intermediate_catch_event,
               :intermediate_throw_event,
               :start_event,
               :user_task
             ]
    end

    test "multi-instance maps isSequential attribute to is_sequential", %{process: process} do
      user_task = find_node(process, "UT_MI")
      assert %MultiInstance{is_sequential: true} = user_task.multi_instance
    end

    test "multi-instance maps evil:inputCollection text to collection_expression", %{
      process: process
    } do
      user_task = find_node(process, "UT_MI")

      assert %MultiInstance{collection_expression: "token.items"} = user_task.multi_instance
    end

    test "multi-instance maps evil extension and BPMN child elements", %{process: process} do
      user_task = find_node(process, "UT_MI")

      assert %MultiInstance{
               is_sequential: true,
               collection_expression: "token.items",
               output_collection: "processedItems",
               loop_break_condition: "errorCount > 3",
               loop_interval: "PT1S",
               max_iterations: 100,
               completion_condition: "done = true"
             } = user_task.multi_instance
    end

    test "multi-instance maps evil:elementVariable to element_variable", %{process: process} do
      user_task = find_node(process, "UT_MI")
      assert %MultiInstance{element_variable: "item"} = user_task.multi_instance
    end

    test "multi-instance element_variable is nil when not specified" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
                        xmlns:evil="https://evilengine.dev/schema/bpmn"
                        id="Defs_1">
        <bpmn:process id="P1" isExecutable="true">
          <bpmn:extensionElements><evil:version>1.0.0</evil:version></bpmn:extensionElements>
          <bpmn:startEvent id="Start_1"><bpmn:outgoing>F1</bpmn:outgoing></bpmn:startEvent>
          <bpmn:task id="Task_1">
            <bpmn:incoming>F1</bpmn:incoming>
            <bpmn:outgoing>F2</bpmn:outgoing>
            <bpmn:multiInstanceLoopCharacteristics isSequential="false">
              <bpmn:extensionElements>
                <evil:inputCollection>token.items</evil:inputCollection>
              </bpmn:extensionElements>
            </bpmn:multiInstanceLoopCharacteristics>
          </bpmn:task>
          <bpmn:endEvent id="End_1"><bpmn:incoming>F2</bpmn:incoming></bpmn:endEvent>
          <bpmn:sequenceFlow id="F1" sourceRef="Start_1" targetRef="Task_1"/>
          <bpmn:sequenceFlow id="F2" sourceRef="Task_1" targetRef="End_1"/>
        </bpmn:process>
      </bpmn:definitions>
      """

      {:ok, definitions} = Parser.parse(xml)
      [process] = definitions.processes
      task = find_node(process, "Task_1")
      assert task.multi_instance.element_variable == nil
    end

    test "link throw maps name attribute to link_name", %{process: process} do
      link_throw = find_node(process, "Link_Throw")

      assert %FlowNodeData.IntermediateThrowEvent{
               event_definition: %EventDefinition.Link{link_name: "jump-target"}
             } = link_throw.type_data

      refute Map.has_key?(link_throw.type_data.event_definition, :name)
    end

    test "link catch maps name attribute to link_name", %{process: process} do
      link_catch = find_node(process, "Link_Catch")

      assert %FlowNodeData.IntermediateCatchEvent{
               event_definition: %EventDefinition.Link{link_name: "jump-target"}
             } = link_catch.type_data
    end
  end

  describe "parse/1 — parser_coverage_standard_loop.bpmn" do
    setup do
      {:ok, definitions} = Parser.parse(read_fixture("parser_coverage_standard_loop.bpmn"))
      [process] = definitions.processes
      %{process: process}
    end

    test "standard loop maps testBefore attribute", %{process: process} do
      script_task = find_node(process, "Script_Loop")
      assert script_task.standard_loop != nil
      assert script_task.standard_loop.test_before == true
    end

    test "standard loop maps loopMaximum attribute", %{process: process} do
      script_task = find_node(process, "Script_Loop")
      assert script_task.standard_loop.loop_maximum == 10
    end

    test "standard loop maps loopCondition child element", %{process: process} do
      script_task = find_node(process, "Script_Loop")
      assert script_task.standard_loop.loop_condition == "token.counter < 5"
    end

    test "standard loop maps evil:loopInterval extension", %{process: process} do
      script_task = find_node(process, "Script_Loop")
      assert script_task.standard_loop.loop_interval == "PT1S"
    end

    test "standard loop is nil on nodes without loop characteristics", %{process: process} do
      start_event = find_node(process, "Start_1")
      assert start_event.standard_loop == nil
    end

    test "standard loop defaults testBefore to false when attribute absent" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
                        xmlns:evil="https://evilengine.dev/schema/bpmn"
                        id="Defs_1">
        <bpmn:process id="P1" isExecutable="true">
          <bpmn:extensionElements><evil:version>1.0.0</evil:version></bpmn:extensionElements>
          <bpmn:startEvent id="Start_1"><bpmn:outgoing>F1</bpmn:outgoing></bpmn:startEvent>
          <bpmn:scriptTask id="Script_1" scriptFormat="feel">
            <bpmn:script>{ counter: loop.completed + 1 }</bpmn:script>
            <bpmn:incoming>F1</bpmn:incoming>
            <bpmn:outgoing>F2</bpmn:outgoing>
            <bpmn:standardLoopCharacteristics loopMaximum="5">
              <bpmn:loopCondition>token.counter &lt; 3</bpmn:loopCondition>
            </bpmn:standardLoopCharacteristics>
          </bpmn:scriptTask>
          <bpmn:endEvent id="End_1"><bpmn:incoming>F2</bpmn:incoming></bpmn:endEvent>
          <bpmn:sequenceFlow id="F1" sourceRef="Start_1" targetRef="Script_1"/>
          <bpmn:sequenceFlow id="F2" sourceRef="Script_1" targetRef="End_1"/>
        </bpmn:process>
      </bpmn:definitions>
      """

      {:ok, definitions} = Parser.parse(xml)
      [process] = definitions.processes
      script_task = find_node(process, "Script_1")
      assert %StandardLoop{test_before: false, loop_maximum: 5} = script_task.standard_loop
    end

    test "standard loop without loopMaximum leaves field nil" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
                        xmlns:evil="https://evilengine.dev/schema/bpmn"
                        id="Defs_1">
        <bpmn:process id="P1" isExecutable="true">
          <bpmn:extensionElements><evil:version>1.0.0</evil:version></bpmn:extensionElements>
          <bpmn:startEvent id="Start_1"><bpmn:outgoing>F1</bpmn:outgoing></bpmn:startEvent>
          <bpmn:scriptTask id="Script_1" scriptFormat="feel">
            <bpmn:script>{ counter: loop.completed + 1 }</bpmn:script>
            <bpmn:incoming>F1</bpmn:incoming>
            <bpmn:outgoing>F2</bpmn:outgoing>
            <bpmn:standardLoopCharacteristics>
              <bpmn:loopCondition>token.counter &lt; 3</bpmn:loopCondition>
            </bpmn:standardLoopCharacteristics>
          </bpmn:scriptTask>
          <bpmn:endEvent id="End_1"><bpmn:incoming>F2</bpmn:incoming></bpmn:endEvent>
          <bpmn:sequenceFlow id="F1" sourceRef="Start_1" targetRef="Script_1"/>
          <bpmn:sequenceFlow id="F2" sourceRef="Script_1" targetRef="End_1"/>
        </bpmn:process>
      </bpmn:definitions>
      """

      {:ok, definitions} = Parser.parse(xml)
      [process] = definitions.processes
      script_task = find_node(process, "Script_1")
      assert script_task.standard_loop.loop_maximum == nil
    end
  end

  describe "parse/1 — gateway types (inline XML)" do
    test "exclusive gateway maps default attribute to default_flow_ref" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
                        xmlns:evil="https://evilengine.dev/schema/bpmn"
                        id="Defs_1">
        <bpmn:process id="P1" name="Test" isExecutable="true">
          <bpmn:extensionElements><evil:version>1.0.0</evil:version></bpmn:extensionElements>
          <bpmn:startEvent id="Start_1"><bpmn:outgoing>F1</bpmn:outgoing></bpmn:startEvent>
          <bpmn:exclusiveGateway id="GW_1" name="Approved?" default="Flow_default">
            <bpmn:incoming>F1</bpmn:incoming>
            <bpmn:outgoing>Flow_yes</bpmn:outgoing>
            <bpmn:outgoing>Flow_default</bpmn:outgoing>
          </bpmn:exclusiveGateway>
          <bpmn:endEvent id="End_1"><bpmn:incoming>Flow_yes</bpmn:incoming></bpmn:endEvent>
          <bpmn:endEvent id="End_2"><bpmn:incoming>Flow_default</bpmn:incoming></bpmn:endEvent>
          <bpmn:sequenceFlow id="F1" sourceRef="Start_1" targetRef="GW_1"/>
          <bpmn:sequenceFlow id="Flow_yes" sourceRef="GW_1" targetRef="End_1"/>
          <bpmn:sequenceFlow id="Flow_default" sourceRef="GW_1" targetRef="End_2"/>
        </bpmn:process>
      </bpmn:definitions>
      """

      {:ok, definitions} = Parser.parse(xml)
      [process] = definitions.processes
      gateway = find_node(process, "GW_1")

      assert gateway.id == "GW_1"
      assert gateway.name == "Approved?"
      assert gateway.type == :exclusive_gateway

      assert %FlowNodeData.ExclusiveGateway{default_flow_ref: "Flow_default"} =
               gateway.type_data
    end

    test "parallel gateway parses id, name, and type" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
                        xmlns:evil="https://evilengine.dev/schema/bpmn"
                        id="Defs_1">
        <bpmn:process id="P1" name="Test" isExecutable="true">
          <bpmn:extensionElements><evil:version>1.0.0</evil:version></bpmn:extensionElements>
          <bpmn:startEvent id="Start_1"><bpmn:outgoing>F1</bpmn:outgoing></bpmn:startEvent>
          <bpmn:parallelGateway id="PG_1" name="Fork">
            <bpmn:incoming>F1</bpmn:incoming>
            <bpmn:outgoing>F2</bpmn:outgoing>
          </bpmn:parallelGateway>
          <bpmn:endEvent id="End_1"><bpmn:incoming>F2</bpmn:incoming></bpmn:endEvent>
          <bpmn:sequenceFlow id="F1" sourceRef="Start_1" targetRef="PG_1"/>
          <bpmn:sequenceFlow id="F2" sourceRef="PG_1" targetRef="End_1"/>
        </bpmn:process>
      </bpmn:definitions>
      """

      {:ok, definitions} = Parser.parse(xml)
      [process] = definitions.processes
      gateway = find_node(process, "PG_1")

      assert gateway.id == "PG_1"
      assert gateway.name == "Fork"
      assert gateway.type == :parallel_gateway
      assert %FlowNodeData.ParallelGateway{} = gateway.type_data
    end

    test "inclusive gateway parses id, name, and type" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
                        xmlns:evil="https://evilengine.dev/schema/bpmn"
                        id="Defs_1">
        <bpmn:process id="P1" name="Test" isExecutable="true">
          <bpmn:extensionElements><evil:version>1.0.0</evil:version></bpmn:extensionElements>
          <bpmn:startEvent id="Start_1"><bpmn:outgoing>F1</bpmn:outgoing></bpmn:startEvent>
          <bpmn:inclusiveGateway id="IG_1" name="Merge">
            <bpmn:incoming>F1</bpmn:incoming>
            <bpmn:outgoing>F2</bpmn:outgoing>
          </bpmn:inclusiveGateway>
          <bpmn:endEvent id="End_1"><bpmn:incoming>F2</bpmn:incoming></bpmn:endEvent>
          <bpmn:sequenceFlow id="F1" sourceRef="Start_1" targetRef="IG_1"/>
          <bpmn:sequenceFlow id="F2" sourceRef="IG_1" targetRef="End_1"/>
        </bpmn:process>
      </bpmn:definitions>
      """

      {:ok, definitions} = Parser.parse(xml)
      [process] = definitions.processes
      gateway = find_node(process, "IG_1")

      assert gateway.id == "IG_1"
      assert gateway.name == "Merge"
      assert gateway.type == :inclusive_gateway
      assert %FlowNodeData.InclusiveGateway{} = gateway.type_data
    end
  end

  describe "parse/1 — businessRuleTask (inline XML)" do
    test "feel mode parses implementation attribute and script child" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
                        xmlns:evil="https://evilengine.dev/schema/bpmn"
                        id="Defs_1">
        <bpmn:process id="P1" name="Test" isExecutable="true">
          <bpmn:extensionElements><evil:version>1.0.0</evil:version></bpmn:extensionElements>
          <bpmn:startEvent id="Start_1"><bpmn:outgoing>F1</bpmn:outgoing></bpmn:startEvent>
          <bpmn:businessRuleTask id="BRT_1" name="Discount Rule" implementation="feel">
            <bpmn:script>{ discount: if token.amount > 100 then 0.1 else 0 }</bpmn:script>
            <bpmn:incoming>F1</bpmn:incoming>
            <bpmn:outgoing>F2</bpmn:outgoing>
          </bpmn:businessRuleTask>
          <bpmn:endEvent id="End_1"><bpmn:incoming>F2</bpmn:incoming></bpmn:endEvent>
          <bpmn:sequenceFlow id="F1" sourceRef="Start_1" targetRef="BRT_1"/>
          <bpmn:sequenceFlow id="F2" sourceRef="BRT_1" targetRef="End_1"/>
        </bpmn:process>
      </bpmn:definitions>
      """

      {:ok, definitions} = Parser.parse(xml)
      [process] = definitions.processes
      business_rule_task = find_node(process, "BRT_1")

      assert %FlowNodeData.BusinessRuleTask{
               implementation: "feel",
               script: "{ discount: if token.amount > 100 then 0.1 else 0 }",
               decision_ref: nil,
               decision_element_id: nil
             } = business_rule_task.type_data
    end

    test "dmn mode parses decisionRef and decisionElementId extensions" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
                        xmlns:evil="https://evilengine.dev/schema/bpmn"
                        id="Defs_1">
        <bpmn:process id="P1" name="Test" isExecutable="true">
          <bpmn:extensionElements><evil:version>1.0.0</evil:version></bpmn:extensionElements>
          <bpmn:startEvent id="Start_1"><bpmn:outgoing>F1</bpmn:outgoing></bpmn:startEvent>
          <bpmn:businessRuleTask id="BRT_1" name="Evaluate Table" implementation="dmn">
            <bpmn:extensionElements>
              <evil:decisionRef>discount-rules</evil:decisionRef>
              <evil:decisionElementId>Decision_Discount</evil:decisionElementId>
            </bpmn:extensionElements>
            <bpmn:incoming>F1</bpmn:incoming>
            <bpmn:outgoing>F2</bpmn:outgoing>
          </bpmn:businessRuleTask>
          <bpmn:endEvent id="End_1"><bpmn:incoming>F2</bpmn:incoming></bpmn:endEvent>
          <bpmn:sequenceFlow id="F1" sourceRef="Start_1" targetRef="BRT_1"/>
          <bpmn:sequenceFlow id="F2" sourceRef="BRT_1" targetRef="End_1"/>
        </bpmn:process>
      </bpmn:definitions>
      """

      {:ok, definitions} = Parser.parse(xml)
      [process] = definitions.processes
      business_rule_task = find_node(process, "BRT_1")

      assert %FlowNodeData.BusinessRuleTask{
               implementation: "dmn",
               decision_ref: "discount-rules",
               decision_element_id: "Decision_Discount",
               script: nil
             } = business_rule_task.type_data
    end
  end

  describe "parse/1 — event definitions (inline XML)" do
    test "timer event definition maps timeDuration child to time_duration" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
                        xmlns:evil="https://evilengine.dev/schema/bpmn"
                        id="Defs_1">
        <bpmn:process id="P1" name="Test" isExecutable="true">
          <bpmn:extensionElements><evil:version>1.0.0</evil:version></bpmn:extensionElements>
          <bpmn:startEvent id="Start_1"><bpmn:outgoing>F1</bpmn:outgoing></bpmn:startEvent>
          <bpmn:intermediateCatchEvent id="Catch_1" name="Wait">
            <bpmn:timerEventDefinition>
              <bpmn:timeDuration>PT5M</bpmn:timeDuration>
            </bpmn:timerEventDefinition>
            <bpmn:incoming>F1</bpmn:incoming>
            <bpmn:outgoing>F2</bpmn:outgoing>
          </bpmn:intermediateCatchEvent>
          <bpmn:endEvent id="End_1"><bpmn:incoming>F2</bpmn:incoming></bpmn:endEvent>
          <bpmn:sequenceFlow id="F1" sourceRef="Start_1" targetRef="Catch_1"/>
          <bpmn:sequenceFlow id="F2" sourceRef="Catch_1" targetRef="End_1"/>
        </bpmn:process>
      </bpmn:definitions>
      """

      {:ok, definitions} = Parser.parse(xml)
      [process] = definitions.processes
      catch_event = find_node(process, "Catch_1")

      assert %FlowNodeData.IntermediateCatchEvent{
               event_definition: %EventDefinition.Timer{time_duration: "PT5M"}
             } = catch_event.type_data
    end

    test "error event definition maps errorRef attribute to error_ref" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
                        xmlns:evil="https://evilengine.dev/schema/bpmn"
                        id="Defs_1">
        <bpmn:error id="Err_1" name="ValidationError" errorCode="VALIDATION_FAILED"/>
        <bpmn:process id="P1" name="Test" isExecutable="true">
          <bpmn:extensionElements><evil:version>1.0.0</evil:version></bpmn:extensionElements>
          <bpmn:startEvent id="Start_1"><bpmn:outgoing>F1</bpmn:outgoing></bpmn:startEvent>
          <bpmn:userTask id="Task_1">
            <bpmn:incoming>F1</bpmn:incoming>
            <bpmn:outgoing>F2</bpmn:outgoing>
          </bpmn:userTask>
          <bpmn:boundaryEvent id="Boundary_1" attachedToRef="Task_1" cancelActivity="true">
            <bpmn:errorEventDefinition errorRef="Err_1"/>
            <bpmn:outgoing>F3</bpmn:outgoing>
          </bpmn:boundaryEvent>
          <bpmn:endEvent id="End_1"><bpmn:incoming>F2</bpmn:incoming></bpmn:endEvent>
          <bpmn:endEvent id="End_2"><bpmn:incoming>F3</bpmn:incoming></bpmn:endEvent>
          <bpmn:sequenceFlow id="F1" sourceRef="Start_1" targetRef="Task_1"/>
          <bpmn:sequenceFlow id="F2" sourceRef="Task_1" targetRef="End_1"/>
          <bpmn:sequenceFlow id="F3" sourceRef="Boundary_1" targetRef="End_2"/>
        </bpmn:process>
      </bpmn:definitions>
      """

      {:ok, definitions} = Parser.parse(xml)
      [process] = definitions.processes
      boundary_event = find_node(process, "Boundary_1")

      assert %FlowNodeData.BoundaryEvent{
               event_definition: %EventDefinition.Error{error_ref: "Err_1"}
             } = boundary_event.type_data
    end

    test "terminate event definition is stored on end event event_definition" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
                        xmlns:evil="https://evilengine.dev/schema/bpmn"
                        id="Defs_1">
        <bpmn:process id="P1" name="Test" isExecutable="true">
          <bpmn:extensionElements><evil:version>1.0.0</evil:version></bpmn:extensionElements>
          <bpmn:startEvent id="Start_1"><bpmn:outgoing>F1</bpmn:outgoing></bpmn:startEvent>
          <bpmn:endEvent id="End_Terminate" name="Terminate">
            <bpmn:terminateEventDefinition/>
            <bpmn:incoming>F1</bpmn:incoming>
          </bpmn:endEvent>
          <bpmn:sequenceFlow id="F1" sourceRef="Start_1" targetRef="End_Terminate"/>
        </bpmn:process>
      </bpmn:definitions>
      """

      {:ok, definitions} = Parser.parse(xml)
      [process] = definitions.processes
      end_event = find_node(process, "End_Terminate")

      assert %FlowNodeData.EndEvent{event_definition: %EventDefinition.Terminate{}} =
               end_event.type_data
    end
  end

  describe "parse/1 — sequence flow features (inline XML)" do
    test "conditionExpression on sequence flow maps to condition_expression" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
                        xmlns:evil="https://evilengine.dev/schema/bpmn"
                        id="Defs_1">
        <bpmn:process id="P1" name="Test" isExecutable="true">
          <bpmn:extensionElements><evil:version>1.0.0</evil:version></bpmn:extensionElements>
          <bpmn:startEvent id="Start_1"><bpmn:outgoing>F1</bpmn:outgoing></bpmn:startEvent>
          <bpmn:exclusiveGateway id="GW_1" name="Split">
            <bpmn:incoming>F1</bpmn:incoming>
            <bpmn:outgoing>Flow_yes</bpmn:outgoing>
            <bpmn:outgoing>Flow_no</bpmn:outgoing>
          </bpmn:exclusiveGateway>
          <bpmn:endEvent id="End_1"><bpmn:incoming>Flow_yes</bpmn:incoming></bpmn:endEvent>
          <bpmn:endEvent id="End_2"><bpmn:incoming>Flow_no</bpmn:incoming></bpmn:endEvent>
          <bpmn:sequenceFlow id="F1" sourceRef="Start_1" targetRef="GW_1"/>
          <bpmn:sequenceFlow id="Flow_yes" sourceRef="GW_1" targetRef="End_1">
            <bpmn:conditionExpression>token.approved = true</bpmn:conditionExpression>
          </bpmn:sequenceFlow>
          <bpmn:sequenceFlow id="Flow_no" sourceRef="GW_1" targetRef="End_2"/>
        </bpmn:process>
      </bpmn:definitions>
      """

      {:ok, definitions} = Parser.parse(xml)
      [process] = definitions.processes

      conditional_flow =
        Enum.find(process.sequence_flows, &(&1.id == "Flow_yes"))

      assert %SequenceFlow{
               id: "Flow_yes",
               source_ref: "GW_1",
               target_ref: "End_1",
               condition_expression: "token.approved = true",
               is_default: false
             } = conditional_flow
    end

    test "gateway default attribute sets is_default on the target sequence flow" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
                        xmlns:evil="https://evilengine.dev/schema/bpmn"
                        id="Defs_1">
        <bpmn:process id="P1" name="Test" isExecutable="true">
          <bpmn:extensionElements><evil:version>1.0.0</evil:version></bpmn:extensionElements>
          <bpmn:startEvent id="Start_1"><bpmn:outgoing>F1</bpmn:outgoing></bpmn:startEvent>
          <bpmn:exclusiveGateway id="GW_1" name="Split" default="Flow_default">
            <bpmn:incoming>F1</bpmn:incoming>
            <bpmn:outgoing>Flow_yes</bpmn:outgoing>
            <bpmn:outgoing>Flow_default</bpmn:outgoing>
          </bpmn:exclusiveGateway>
          <bpmn:endEvent id="End_1"><bpmn:incoming>Flow_yes</bpmn:incoming></bpmn:endEvent>
          <bpmn:endEvent id="End_2"><bpmn:incoming>Flow_default</bpmn:incoming></bpmn:endEvent>
          <bpmn:sequenceFlow id="F1" sourceRef="Start_1" targetRef="GW_1"/>
          <bpmn:sequenceFlow id="Flow_yes" sourceRef="GW_1" targetRef="End_1"/>
          <bpmn:sequenceFlow id="Flow_default" sourceRef="GW_1" targetRef="End_2"/>
        </bpmn:process>
      </bpmn:definitions>
      """

      {:ok, definitions} = Parser.parse(xml)
      [process] = definitions.processes

      default_flow =
        Enum.find(process.sequence_flows, &(&1.id == "Flow_default"))

      non_default_flow =
        Enum.find(process.sequence_flows, &(&1.id == "Flow_yes"))

      assert %SequenceFlow{is_default: true} = default_flow
      assert %SequenceFlow{is_default: false} = non_default_flow
    end
  end

  describe "parse/1 — extension elements (inline XML)" do
    test "evil:formFields on user task maps JSON to form_schema" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
                        xmlns:evil="https://evilengine.dev/schema/bpmn"
                        id="Defs_1">
        <bpmn:process id="P1" name="Test" isExecutable="true">
          <bpmn:extensionElements><evil:version>1.0.0</evil:version></bpmn:extensionElements>
          <bpmn:startEvent id="Start_1"><bpmn:outgoing>F1</bpmn:outgoing></bpmn:startEvent>
          <bpmn:userTask id="Task_1" name="Review">
            <bpmn:extensionElements>
              <evil:formFields>{"fields":[{"name":"approved","type":"boolean"}]}</evil:formFields>
            </bpmn:extensionElements>
            <bpmn:incoming>F1</bpmn:incoming>
            <bpmn:outgoing>F2</bpmn:outgoing>
          </bpmn:userTask>
          <bpmn:endEvent id="End_1"><bpmn:incoming>F2</bpmn:incoming></bpmn:endEvent>
          <bpmn:sequenceFlow id="F1" sourceRef="Start_1" targetRef="Task_1"/>
          <bpmn:sequenceFlow id="F2" sourceRef="Task_1" targetRef="End_1"/>
        </bpmn:process>
      </bpmn:definitions>
      """

      {:ok, definitions} = Parser.parse(xml)
      [process] = definitions.processes
      user_task = find_node(process, "Task_1")

      assert %FlowNodeData.UserTask{
               form_schema: %{
                 "fields" => [%{"name" => "approved", "type" => "boolean"}]
               }
             } = user_task.type_data
    end

    test "evil:httpUrl and evil:httpMethod on service task map to HTTP extension fields" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
                        xmlns:evil="https://evilengine.dev/schema/bpmn"
                        id="Defs_1">
        <bpmn:process id="P1" name="Test" isExecutable="true">
          <bpmn:extensionElements><evil:version>1.0.0</evil:version></bpmn:extensionElements>
          <bpmn:startEvent id="Start_1"><bpmn:outgoing>F1</bpmn:outgoing></bpmn:startEvent>
          <bpmn:serviceTask id="Task_1" name="Call API" implementation="http">
            <bpmn:extensionElements>
              <evil:httpUrl>https://api.example.com/v1/echo</evil:httpUrl>
              <evil:httpMethod>post</evil:httpMethod>
            </bpmn:extensionElements>
            <bpmn:incoming>F1</bpmn:incoming>
            <bpmn:outgoing>F2</bpmn:outgoing>
          </bpmn:serviceTask>
          <bpmn:endEvent id="End_1"><bpmn:incoming>F2</bpmn:incoming></bpmn:endEvent>
          <bpmn:sequenceFlow id="F1" sourceRef="Start_1" targetRef="Task_1"/>
          <bpmn:sequenceFlow id="F2" sourceRef="Task_1" targetRef="End_1"/>
        </bpmn:process>
      </bpmn:definitions>
      """

      {:ok, definitions} = Parser.parse(xml)
      [process] = definitions.processes
      service_task = find_node(process, "Task_1")

      assert %FlowNodeData.ServiceTask{
               implementation: "http",
               http_url: "https://api.example.com/v1/echo",
               http_method: "POST"
             } = service_task.type_data
    end
  end

  describe "parse/1 — nested childLaneSet" do
    test "flattens child lanes into the parent lane set without crashing" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
                        xmlns:evil="https://evilengine.dev/schema/bpmn"
                        id="Definitions_1">
        <bpmn:process id="Process_1" isExecutable="true">
          <bpmn:extensionElements>
            <evil:version>1.0.0</evil:version>
          </bpmn:extensionElements>
          <bpmn:startEvent id="Start_1" />
          <bpmn:endEvent id="End_1" />
          <bpmn:sequenceFlow id="Flow_1" sourceRef="Start_1" targetRef="End_1" />
          <bpmn:laneSet id="LaneSet_1">
            <bpmn:lane id="Lane_Parent" name="Parent">
              <bpmn:flowNodeRef>Start_1</bpmn:flowNodeRef>
              <bpmn:childLaneSet id="ChildLaneSet_1">
                <bpmn:lane id="Lane_Child" name="Child">
                  <bpmn:flowNodeRef>End_1</bpmn:flowNodeRef>
                </bpmn:lane>
              </bpmn:childLaneSet>
            </bpmn:lane>
          </bpmn:laneSet>
        </bpmn:process>
      </bpmn:definitions>
      """

      assert {:ok, definitions} = Parser.parse(xml)
      [process] = definitions.processes

      lane_ids = Enum.map(process.lanes, & &1.id) |> Enum.sort()
      assert lane_ids == ["Lane_Child", "Lane_Parent"]

      parent_lane = Enum.find(process.lanes, &(&1.id == "Lane_Parent"))
      child_lane = Enum.find(process.lanes, &(&1.id == "Lane_Child"))

      assert parent_lane.flow_node_refs == ["Start_1"]
      assert child_lane.flow_node_refs == ["End_1"]
    end
  end

  describe "bpmn:transaction parsing" do
    test "parses transaction as :sub_process with is_transaction: true" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
                        xmlns:evil="https://evilengine.dev/schema/bpmn"
                        id="Defs_TX">
        <bpmn:process id="Process_TX" isExecutable="true">
          <bpmn:extensionElements><evil:version>1.0.0</evil:version></bpmn:extensionElements>
          <bpmn:startEvent id="Start_1"><bpmn:outgoing>F1</bpmn:outgoing></bpmn:startEvent>
          <bpmn:transaction id="TX_1" name="My Transaction" method="##WebServiceAT">
            <bpmn:startEvent id="TX_Start"><bpmn:outgoing>TF1</bpmn:outgoing></bpmn:startEvent>
            <bpmn:endEvent id="TX_End"><bpmn:incoming>TF1</bpmn:incoming></bpmn:endEvent>
            <bpmn:sequenceFlow id="TF1" sourceRef="TX_Start" targetRef="TX_End"/>
            <bpmn:incoming>F1</bpmn:incoming>
            <bpmn:outgoing>F2</bpmn:outgoing>
          </bpmn:transaction>
          <bpmn:endEvent id="End_1"><bpmn:incoming>F2</bpmn:incoming></bpmn:endEvent>
          <bpmn:sequenceFlow id="F1" sourceRef="Start_1" targetRef="TX_1"/>
          <bpmn:sequenceFlow id="F2" sourceRef="TX_1" targetRef="End_1"/>
        </bpmn:process>
      </bpmn:definitions>
      """

      {:ok, definitions} = Parser.parse(xml)
      [process] = definitions.processes

      tx_node = find_node(process, "TX_1")
      assert tx_node.type == :sub_process
      assert tx_node.name == "My Transaction"
      assert %FlowNodeData.SubProcess{
               is_transaction: true,
               transaction_method: "##WebServiceAT",
               triggered_by_event: false
             } = tx_node.type_data

      assert length(tx_node.type_data.flow_nodes) == 2
      assert Enum.any?(tx_node.type_data.flow_nodes, &(&1.id == "TX_Start"))
      assert Enum.any?(tx_node.type_data.flow_nodes, &(&1.id == "TX_End"))
    end

    test "parses transaction without method attribute" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
                        xmlns:evil="https://evilengine.dev/schema/bpmn"
                        id="Defs_TX2">
        <bpmn:process id="Process_TX2" isExecutable="true">
          <bpmn:extensionElements><evil:version>1.0.0</evil:version></bpmn:extensionElements>
          <bpmn:startEvent id="Start_1"><bpmn:outgoing>F1</bpmn:outgoing></bpmn:startEvent>
          <bpmn:transaction id="TX_2">
            <bpmn:startEvent id="TX_Start"><bpmn:outgoing>TF1</bpmn:outgoing></bpmn:startEvent>
            <bpmn:endEvent id="TX_End"><bpmn:incoming>TF1</bpmn:incoming></bpmn:endEvent>
            <bpmn:sequenceFlow id="TF1" sourceRef="TX_Start" targetRef="TX_End"/>
            <bpmn:incoming>F1</bpmn:incoming>
            <bpmn:outgoing>F2</bpmn:outgoing>
          </bpmn:transaction>
          <bpmn:endEvent id="End_1"><bpmn:incoming>F2</bpmn:incoming></bpmn:endEvent>
          <bpmn:sequenceFlow id="F1" sourceRef="Start_1" targetRef="TX_2"/>
          <bpmn:sequenceFlow id="F2" sourceRef="TX_2" targetRef="End_1"/>
        </bpmn:process>
      </bpmn:definitions>
      """

      {:ok, definitions} = Parser.parse(xml)
      [process] = definitions.processes
      tx_node = find_node(process, "TX_2")

      assert %FlowNodeData.SubProcess{is_transaction: true, transaction_method: nil} = tx_node.type_data
    end

    test "regular subProcess still has is_transaction: false" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
                        xmlns:evil="https://evilengine.dev/schema/bpmn"
                        id="Defs_SP">
        <bpmn:process id="Process_SP" isExecutable="true">
          <bpmn:extensionElements><evil:version>1.0.0</evil:version></bpmn:extensionElements>
          <bpmn:startEvent id="Start_1"><bpmn:outgoing>F1</bpmn:outgoing></bpmn:startEvent>
          <bpmn:subProcess id="SP_1">
            <bpmn:startEvent id="SP_Start"><bpmn:outgoing>SF1</bpmn:outgoing></bpmn:startEvent>
            <bpmn:endEvent id="SP_End"><bpmn:incoming>SF1</bpmn:incoming></bpmn:endEvent>
            <bpmn:sequenceFlow id="SF1" sourceRef="SP_Start" targetRef="SP_End"/>
            <bpmn:incoming>F1</bpmn:incoming>
            <bpmn:outgoing>F2</bpmn:outgoing>
          </bpmn:subProcess>
          <bpmn:endEvent id="End_1"><bpmn:incoming>F2</bpmn:incoming></bpmn:endEvent>
          <bpmn:sequenceFlow id="F1" sourceRef="Start_1" targetRef="SP_1"/>
          <bpmn:sequenceFlow id="F2" sourceRef="SP_1" targetRef="End_1"/>
        </bpmn:process>
      </bpmn:definitions>
      """

      {:ok, definitions} = Parser.parse(xml)
      [process] = definitions.processes
      sp_node = find_node(process, "SP_1")

      assert %FlowNodeData.SubProcess{is_transaction: false, transaction_method: nil} = sp_node.type_data
    end
  end

  describe "bpmn:adHocSubProcess parsing" do
    @adhoc_full_xml """
    <?xml version="1.0" encoding="UTF-8"?>
    <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
                      xmlns:evil="https://evilengine.dev/schema/bpmn"
                      id="Defs_AH">
      <bpmn:process id="Process_AH" isExecutable="true">
        <bpmn:extensionElements><evil:version>1.0.0</evil:version></bpmn:extensionElements>
        <bpmn:startEvent id="Start_1"><bpmn:outgoing>F1</bpmn:outgoing></bpmn:startEvent>
        <bpmn:adHocSubProcess id="AH_1" name="Toolbox" ordering="Sequential"
                              cancelRemainingInstances="false" implementation="ai-agent">
          <bpmn:extensionElements>
            <evil:activeElements>["Task_A", "Task_B"]</evil:activeElements>
          </bpmn:extensionElements>
          <bpmn:completionCondition>performedActivities.size() >= 2</bpmn:completionCondition>
          <bpmn:task id="Task_A" name="Lookup Order">
            <bpmn:outgoing>AH_Flow_1</bpmn:outgoing>
          </bpmn:task>
          <bpmn:task id="Task_B" name="Send Email">
            <bpmn:incoming>AH_Flow_1</bpmn:incoming>
          </bpmn:task>
          <bpmn:sequenceFlow id="AH_Flow_1" sourceRef="Task_A" targetRef="Task_B"/>
          <bpmn:incoming>F1</bpmn:incoming>
          <bpmn:outgoing>F2</bpmn:outgoing>
        </bpmn:adHocSubProcess>
        <bpmn:endEvent id="End_1"><bpmn:incoming>F2</bpmn:incoming></bpmn:endEvent>
        <bpmn:sequenceFlow id="F1" sourceRef="Start_1" targetRef="AH_1"/>
        <bpmn:sequenceFlow id="F2" sourceRef="AH_1" targetRef="End_1"/>
      </bpmn:process>
    </bpmn:definitions>
    """

    test "parses as :sub_process with is_ad_hoc: true" do
      {:ok, definitions} = Parser.parse(@adhoc_full_xml)
      [process] = definitions.processes
      adhoc_node = find_node(process, "AH_1")

      assert adhoc_node.type == :sub_process
      assert adhoc_node.name == "Toolbox"

      assert %FlowNodeData.SubProcess{
               is_ad_hoc: true,
               is_transaction: false,
               triggered_by_event: false
             } = adhoc_node.type_data
    end

    test "maps ordering='Sequential' to :sequential" do
      {:ok, definitions} = Parser.parse(@adhoc_full_xml)
      [process] = definitions.processes
      adhoc_node = find_node(process, "AH_1")

      assert adhoc_node.type_data.adhoc_ordering == :sequential
    end

    test "maps cancelRemainingInstances='false' to false" do
      {:ok, definitions} = Parser.parse(@adhoc_full_xml)
      [process] = definitions.processes
      adhoc_node = find_node(process, "AH_1")

      assert adhoc_node.type_data.cancel_remaining_instances == false
    end

    test "maps implementation attribute to implementation field" do
      {:ok, definitions} = Parser.parse(@adhoc_full_xml)
      [process] = definitions.processes
      adhoc_node = find_node(process, "AH_1")

      assert adhoc_node.type_data.implementation == "ai-agent"
    end

    test "maps completionCondition child text to adhoc_completion_condition" do
      {:ok, definitions} = Parser.parse(@adhoc_full_xml)
      [process] = definitions.processes
      adhoc_node = find_node(process, "AH_1")

      assert adhoc_node.type_data.adhoc_completion_condition ==
               ~s[performedActivities.size() >= 2]
    end

    test "maps evil:activeElements body to active_elements_expression" do
      {:ok, definitions} = Parser.parse(@adhoc_full_xml)
      [process] = definitions.processes
      adhoc_node = find_node(process, "AH_1")

      assert adhoc_node.type_data.active_elements_expression == ~s(["Task_A", "Task_B"])
    end

    test "parses inner flow nodes into type_data.flow_nodes" do
      {:ok, definitions} = Parser.parse(@adhoc_full_xml)
      [process] = definitions.processes
      adhoc_node = find_node(process, "AH_1")

      assert length(adhoc_node.type_data.flow_nodes) == 2
      inner_ids = Enum.map(adhoc_node.type_data.flow_nodes, & &1.id) |> Enum.sort()
      assert inner_ids == ["Task_A", "Task_B"]
    end

    test "parses inner sequence flows into type_data.sequence_flows" do
      {:ok, definitions} = Parser.parse(@adhoc_full_xml)
      [process] = definitions.processes
      adhoc_node = find_node(process, "AH_1")

      assert [flow] = adhoc_node.type_data.sequence_flows
      assert flow.id == "AH_Flow_1"
      assert flow.source_ref == "Task_A"
      assert flow.target_ref == "Task_B"
    end

    test "inner flow nodes are not added to parent process" do
      {:ok, definitions} = Parser.parse(@adhoc_full_xml)
      [process] = definitions.processes

      parent_ids = MapSet.new(Enum.map(process.flow_nodes, & &1.id))
      refute MapSet.member?(parent_ids, "Task_A")
      refute MapSet.member?(parent_ids, "Task_B")
    end

    test "shell has incoming and outgoing refs" do
      {:ok, definitions} = Parser.parse(@adhoc_full_xml)
      [process] = definitions.processes
      adhoc_node = find_node(process, "AH_1")

      assert adhoc_node.incoming == ["F1"]
      assert adhoc_node.outgoing == ["F2"]
    end

    test "defaults ordering to :parallel when attribute absent" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
                        xmlns:evil="https://evilengine.dev/schema/bpmn"
                        id="Defs_AH2">
        <bpmn:process id="Process_AH2" isExecutable="true">
          <bpmn:extensionElements><evil:version>1.0.0</evil:version></bpmn:extensionElements>
          <bpmn:adHocSubProcess id="AH_2">
            <bpmn:task id="Task_X" name="Something"/>
          </bpmn:adHocSubProcess>
        </bpmn:process>
      </bpmn:definitions>
      """

      {:ok, definitions} = Parser.parse(xml)
      [process] = definitions.processes
      adhoc_node = find_node(process, "AH_2")

      assert adhoc_node.type_data.adhoc_ordering == :parallel
    end

    test "defaults ordering to :parallel for ordering='Parallel'" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
                        xmlns:evil="https://evilengine.dev/schema/bpmn"
                        id="Defs_AH3">
        <bpmn:process id="Process_AH3" isExecutable="true">
          <bpmn:extensionElements><evil:version>1.0.0</evil:version></bpmn:extensionElements>
          <bpmn:adHocSubProcess id="AH_3" ordering="Parallel">
            <bpmn:task id="Task_Y" name="Something"/>
          </bpmn:adHocSubProcess>
        </bpmn:process>
      </bpmn:definitions>
      """

      {:ok, definitions} = Parser.parse(xml)
      [process] = definitions.processes
      adhoc_node = find_node(process, "AH_3")

      assert adhoc_node.type_data.adhoc_ordering == :parallel
    end

    test "unrecognized ordering value defaults to :parallel" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
                        xmlns:evil="https://evilengine.dev/schema/bpmn"
                        id="Defs_AH4">
        <bpmn:process id="Process_AH4" isExecutable="true">
          <bpmn:extensionElements><evil:version>1.0.0</evil:version></bpmn:extensionElements>
          <bpmn:adHocSubProcess id="AH_4" ordering="Garbled">
            <bpmn:task id="Task_Z" name="Something"/>
          </bpmn:adHocSubProcess>
        </bpmn:process>
      </bpmn:definitions>
      """

      {:ok, definitions} = Parser.parse(xml)
      [process] = definitions.processes
      adhoc_node = find_node(process, "AH_4")

      assert adhoc_node.type_data.adhoc_ordering == :parallel
    end

    test "defaults cancelRemainingInstances to true when attribute absent" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
                        xmlns:evil="https://evilengine.dev/schema/bpmn"
                        id="Defs_AH5">
        <bpmn:process id="Process_AH5" isExecutable="true">
          <bpmn:extensionElements><evil:version>1.0.0</evil:version></bpmn:extensionElements>
          <bpmn:adHocSubProcess id="AH_5">
            <bpmn:task id="Task_1" name="Something"/>
          </bpmn:adHocSubProcess>
        </bpmn:process>
      </bpmn:definitions>
      """

      {:ok, definitions} = Parser.parse(xml)
      [process] = definitions.processes
      adhoc_node = find_node(process, "AH_5")

      assert adhoc_node.type_data.cancel_remaining_instances == true
    end

    test "leaves adhoc_completion_condition nil when no completionCondition child" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
                        xmlns:evil="https://evilengine.dev/schema/bpmn"
                        id="Defs_AH6">
        <bpmn:process id="Process_AH6" isExecutable="true">
          <bpmn:extensionElements><evil:version>1.0.0</evil:version></bpmn:extensionElements>
          <bpmn:adHocSubProcess id="AH_6">
            <bpmn:task id="Task_1" name="Something"/>
          </bpmn:adHocSubProcess>
        </bpmn:process>
      </bpmn:definitions>
      """

      {:ok, definitions} = Parser.parse(xml)
      [process] = definitions.processes
      adhoc_node = find_node(process, "AH_6")

      assert adhoc_node.type_data.adhoc_completion_condition == nil
    end

    test "ignores blank completionCondition" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
                        xmlns:evil="https://evilengine.dev/schema/bpmn"
                        id="Defs_AH7">
        <bpmn:process id="Process_AH7" isExecutable="true">
          <bpmn:extensionElements><evil:version>1.0.0</evil:version></bpmn:extensionElements>
          <bpmn:adHocSubProcess id="AH_7">
            <bpmn:completionCondition>   </bpmn:completionCondition>
            <bpmn:task id="Task_1" name="Something"/>
          </bpmn:adHocSubProcess>
        </bpmn:process>
      </bpmn:definitions>
      """

      {:ok, definitions} = Parser.parse(xml)
      [process] = definitions.processes
      adhoc_node = find_node(process, "AH_7")

      assert adhoc_node.type_data.adhoc_completion_condition == nil
    end

    test "leaves active_elements_expression nil when evil:activeElements absent" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
                        xmlns:evil="https://evilengine.dev/schema/bpmn"
                        id="Defs_AH8">
        <bpmn:process id="Process_AH8" isExecutable="true">
          <bpmn:extensionElements><evil:version>1.0.0</evil:version></bpmn:extensionElements>
          <bpmn:adHocSubProcess id="AH_8">
            <bpmn:task id="Task_1" name="Something"/>
          </bpmn:adHocSubProcess>
        </bpmn:process>
      </bpmn:definitions>
      """

      {:ok, definitions} = Parser.parse(xml)
      [process] = definitions.processes
      adhoc_node = find_node(process, "AH_8")

      assert adhoc_node.type_data.active_elements_expression == nil
    end

    test "leaves implementation nil when attribute absent" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
                        xmlns:evil="https://evilengine.dev/schema/bpmn"
                        id="Defs_AH9">
        <bpmn:process id="Process_AH9" isExecutable="true">
          <bpmn:extensionElements><evil:version>1.0.0</evil:version></bpmn:extensionElements>
          <bpmn:adHocSubProcess id="AH_9">
            <bpmn:task id="Task_1" name="Something"/>
          </bpmn:adHocSubProcess>
        </bpmn:process>
      </bpmn:definitions>
      """

      {:ok, definitions} = Parser.parse(xml)
      [process] = definitions.processes
      adhoc_node = find_node(process, "AH_9")

      assert adhoc_node.type_data.implementation == nil
    end

    test "completionCondition inside MI within ad-hoc goes to MI, not ad-hoc" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
                        xmlns:evil="https://evilengine.dev/schema/bpmn"
                        id="Defs_AH_MI">
        <bpmn:process id="Process_AH_MI" isExecutable="true">
          <bpmn:extensionElements><evil:version>1.0.0</evil:version></bpmn:extensionElements>
          <bpmn:adHocSubProcess id="AH_MI">
            <bpmn:completionCondition>all_done</bpmn:completionCondition>
            <bpmn:task id="MI_Task">
              <bpmn:multiInstanceLoopCharacteristics isSequential="true">
                <bpmn:completionCondition>loop_done</bpmn:completionCondition>
                <bpmn:extensionElements>
                  <evil:inputCollection>token.items</evil:inputCollection>
                </bpmn:extensionElements>
              </bpmn:multiInstanceLoopCharacteristics>
            </bpmn:task>
          </bpmn:adHocSubProcess>
        </bpmn:process>
      </bpmn:definitions>
      """

      {:ok, definitions} = Parser.parse(xml)
      [process] = definitions.processes
      adhoc_node = find_node(process, "AH_MI")

      assert adhoc_node.type_data.adhoc_completion_condition == "all_done"

      mi_task = Enum.find(adhoc_node.type_data.flow_nodes, &(&1.id == "MI_Task"))
      assert mi_task.multi_instance.completion_condition == "loop_done"
    end

    test "ad-hoc shell captures evil:payloadContract and evil:resultContract" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
                        xmlns:evil="https://evilengine.dev/schema/bpmn"
                        id="Defs_AH_Contracts">
        <bpmn:process id="Process_AH_C" isExecutable="true">
          <bpmn:extensionElements><evil:version>1.0.0</evil:version></bpmn:extensionElements>
          <bpmn:adHocSubProcess id="AH_C">
            <bpmn:extensionElements>
              <evil:payloadContract>{"type":"object","required":["orderId"]}</evil:payloadContract>
              <evil:resultContract>{"type":"object","required":["status"]}</evil:resultContract>
            </bpmn:extensionElements>
            <bpmn:task id="Task_1" name="Something"/>
          </bpmn:adHocSubProcess>
        </bpmn:process>
      </bpmn:definitions>
      """

      {:ok, definitions} = Parser.parse(xml)
      [process] = definitions.processes
      adhoc_node = find_node(process, "AH_C")

      assert adhoc_node.type_data.payload_contract == %{
               "type" => "object",
               "required" => ["orderId"]
             }

      assert adhoc_node.type_data.result_contract == %{
               "type" => "object",
               "required" => ["status"]
             }
    end

    test "ad-hoc shell captures evil:inputMapping and evil:outputMapping" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
                        xmlns:evil="https://evilengine.dev/schema/bpmn"
                        id="Defs_AH_Mappings">
        <bpmn:process id="Process_AH_M" isExecutable="true">
          <bpmn:extensionElements><evil:version>1.0.0</evil:version></bpmn:extensionElements>
          <bpmn:adHocSubProcess id="AH_M">
            <bpmn:extensionElements>
              <evil:inputMapping source="token.orderId" target="orderId"/>
              <evil:outputMapping source="result.summary" target="summary"/>
            </bpmn:extensionElements>
            <bpmn:task id="Task_1" name="Something"/>
          </bpmn:adHocSubProcess>
        </bpmn:process>
      </bpmn:definitions>
      """

      {:ok, definitions} = Parser.parse(xml)
      [process] = definitions.processes
      adhoc_node = find_node(process, "AH_M")

      assert [%Mapping{source: "token.orderId", target: "orderId"}] =
               adhoc_node.type_data.in_mappings

      assert [%Mapping{source: "result.summary", target: "summary"}] =
               adhoc_node.type_data.out_mappings
    end

    test "regular subProcess does not have is_ad_hoc: true" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
                        xmlns:evil="https://evilengine.dev/schema/bpmn"
                        id="Defs_SP_Check">
        <bpmn:process id="Process_SP_Check" isExecutable="true">
          <bpmn:extensionElements><evil:version>1.0.0</evil:version></bpmn:extensionElements>
          <bpmn:subProcess id="SP_Check">
            <bpmn:startEvent id="SP_Start"/>
          </bpmn:subProcess>
        </bpmn:process>
      </bpmn:definitions>
      """

      {:ok, definitions} = Parser.parse(xml)
      [process] = definitions.processes
      sp_node = find_node(process, "SP_Check")

      assert sp_node.type_data.is_ad_hoc == false
      assert sp_node.type_data.adhoc_ordering == :parallel
      assert sp_node.type_data.cancel_remaining_instances == true
      assert sp_node.type_data.adhoc_completion_condition == nil
    end

    test "ad-hoc inside embedded subprocess parses nested scope" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
                        xmlns:evil="https://evilengine.dev/schema/bpmn"
                        id="Defs_Nested_AH">
        <bpmn:process id="Process_Nested" isExecutable="true">
          <bpmn:extensionElements><evil:version>1.0.0</evil:version></bpmn:extensionElements>
          <bpmn:subProcess id="Outer_SP">
            <bpmn:adHocSubProcess id="Inner_AH" ordering="Sequential">
              <bpmn:task id="Inner_Task_1" name="Tool A"/>
              <bpmn:task id="Inner_Task_2" name="Tool B"/>
            </bpmn:adHocSubProcess>
            <bpmn:startEvent id="Outer_Start"/>
          </bpmn:subProcess>
        </bpmn:process>
      </bpmn:definitions>
      """

      {:ok, definitions} = Parser.parse(xml)
      [process] = definitions.processes
      outer = find_node(process, "Outer_SP")

      assert outer.type_data.is_ad_hoc == false

      inner_adhoc = Enum.find(outer.type_data.flow_nodes, &(&1.id == "Inner_AH"))
      assert inner_adhoc.type_data.is_ad_hoc == true
      assert inner_adhoc.type_data.adhoc_ordering == :sequential
      assert length(inner_adhoc.type_data.flow_nodes) == 2
    end

    test "completionCondition and activeElements parsed when placed after child nodes" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
                        xmlns:evil="https://evilengine.dev/schema/bpmn"
                        id="Defs_AH_After">
        <bpmn:process id="Process_AH_After" isExecutable="true">
          <bpmn:extensionElements><evil:version>1.0.0</evil:version></bpmn:extensionElements>
          <bpmn:adHocSubProcess id="AH_After" ordering="Sequential" implementation="my-plugin">
            <bpmn:task id="Task_First" name="First"/>
            <bpmn:task id="Task_Second" name="Second"/>
            <bpmn:extensionElements>
              <evil:activeElements>["Task_First"]</evil:activeElements>
            </bpmn:extensionElements>
            <bpmn:completionCondition>performedActivities >= 1</bpmn:completionCondition>
          </bpmn:adHocSubProcess>
        </bpmn:process>
      </bpmn:definitions>
      """

      {:ok, definitions} = Parser.parse(xml)
      [process] = definitions.processes
      adhoc_node = find_node(process, "AH_After")

      assert adhoc_node.type_data.is_ad_hoc == true
      assert adhoc_node.type_data.adhoc_completion_condition == "performedActivities >= 1"
      assert adhoc_node.type_data.active_elements_expression == ~s(["Task_First"])
      assert length(adhoc_node.type_data.flow_nodes) == 2
    end

    test "evil:activeElements on non-ad-hoc subprocess is silently ignored" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
                        xmlns:evil="https://evilengine.dev/schema/bpmn"
                        id="Defs_AE_Ignore">
        <bpmn:process id="Process_AE_Ignore" isExecutable="true">
          <bpmn:extensionElements><evil:version>1.0.0</evil:version></bpmn:extensionElements>
          <bpmn:subProcess id="SP_AE">
            <bpmn:extensionElements>
              <evil:activeElements>["Task_1"]</evil:activeElements>
            </bpmn:extensionElements>
            <bpmn:startEvent id="Sub_Start"/>
          </bpmn:subProcess>
        </bpmn:process>
      </bpmn:definitions>
      """

      {:ok, definitions} = Parser.parse(xml)
      [process] = definitions.processes
      sp_node = find_node(process, "SP_AE")

      assert sp_node.type_data.active_elements_expression == nil
    end
  end
end
