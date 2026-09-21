/**
 * Unit tests for the SDK BPMN parser covering happy paths, edge cases,
 * all bfw:* extension elements, and event definition positions.
 */
import { describe, expect, it } from 'vitest';

import { parseBpmn } from '../../src/index.js';
import type {
  BoundaryEventTypeData,
  BusinessRuleTaskTypeData,
  CallActivityTypeData,
  CompensationEventDefinition,
  ComplexGatewayTypeData,
  EndEventTypeData,
  ErrorEventDefinition,
  EscalationEventDefinition,
  ExclusiveGatewayTypeData,
  IntermediateCatchEventTypeData,
  IntermediateThrowEventTypeData,
  LinkEventDefinition,
  ManualTaskTypeData,
  MessageEventDefinition,
  ReceiveTaskTypeData,
  ScriptTaskTypeData,
  SendTaskTypeData,
  ServiceTaskTypeData,
  SignalEventDefinition,
  StartEventTypeData,
  SubProcessTypeData,
  TimerEventDefinition,
  UserTaskTypeData,
} from '../../src/index.js';

function wrap(processBody: string, extras = ''): string {
  return `<?xml version="1.0" encoding="UTF-8"?>
<bpmn:definitions
  xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
  xmlns:bfw="https://bifrostforge.world/schema/bpmn"
  id="Definitions_1"
  ${extras}>
  ${processBody}
</bpmn:definitions>`;
}

function processWrap(processId: string, body: string, version = '1.0.0'): string {
  return wrap(`
    <bpmn:process id="${processId}" name="${processId}" isExecutable="true">
      <bpmn:extensionElements>
        <bfw:version>${version}</bfw:version>
      </bpmn:extensionElements>
      ${body}
    </bpmn:process>
  `);
}

describe('parseBpmn', () => {
  // -------------------------------------------------------------------------
  // Happy path
  // -------------------------------------------------------------------------

  describe('happy path', () => {
    it('parses a minimal start-end process', () => {
      const xml = processWrap(
        'MinimalProcess',
        `
        <bpmn:startEvent id="S1" name="Start"/>
        <bpmn:endEvent id="E1" name="End"/>
        <bpmn:sequenceFlow id="F1" sourceRef="S1" targetRef="E1"/>
      `,
      );

      const result = parseBpmn(xml);
      expect(result.definitionsId).toBe('Definitions_1');
      expect(result.processes).toHaveLength(1);

      const process = result.processes[0]!;
      expect(process.id).toBe('MinimalProcess');
      expect(process.version).toBe('1.0.0');
      expect(process.isExecutable).toBe(true);

      expect(process.flowNodes).toHaveLength(2);
      expect(process.flowNodes[0]!.type).toBe('start_event');
      expect(process.flowNodes[1]!.type).toBe('end_event');

      expect(process.sequenceFlows).toHaveLength(1);
      expect(process.sequenceFlows[0]!.sourceRef).toBe('S1');
      expect(process.sequenceFlows[0]!.targetRef).toBe('E1');
      expect(process.sequenceFlows[0]!.isDefault).toBe(false);
    });

    it('parses process version from bfw:version', () => {
      const xml = processWrap('V', '<bpmn:startEvent id="S1"/>', '2.5.0');
      const result = parseBpmn(xml);
      expect(result.processes[0]!.version).toBe('2.5.0');
    });

    it('parses definitions-level global definitions', () => {
      const xml = wrap(`
        <bpmn:message id="Msg_1" name="OrderReceived"/>
        <bpmn:signal id="Sig_1" name="AllDone"/>
        <bpmn:error id="Err_1" name="Timeout" errorCode="ERR_TIMEOUT"/>
        <bpmn:escalation id="Esc_1" name="ManagerReview" escalationCode="ESC_REVIEW"/>
        <bpmn:process id="P" isExecutable="true">
          <bpmn:extensionElements><bfw:version>1.0.0</bfw:version></bpmn:extensionElements>
          <bpmn:startEvent id="S1"/>
        </bpmn:process>
      `);

      const result = parseBpmn(xml);
      expect(result.messages).toHaveLength(1);
      expect(result.messages[0]).toEqual({ id: 'Msg_1', name: 'OrderReceived' });

      expect(result.signals).toHaveLength(1);
      expect(result.signals[0]).toEqual({ id: 'Sig_1', name: 'AllDone' });

      expect(result.errors).toHaveLength(1);
      expect(result.errors[0]).toEqual({
        id: 'Err_1',
        name: 'Timeout',
        errorCode: 'ERR_TIMEOUT',
      });

      expect(result.escalations).toHaveLength(1);
      expect(result.escalations[0]).toEqual({
        id: 'Esc_1',
        name: 'ManagerReview',
        escalationCode: 'ESC_REVIEW',
      });
    });

    it('parses multiple processes', () => {
      const xml = wrap(`
        <bpmn:process id="P1" isExecutable="true">
          <bpmn:extensionElements><bfw:version>1.0.0</bfw:version></bpmn:extensionElements>
          <bpmn:startEvent id="S1"/>
        </bpmn:process>
        <bpmn:process id="P2" isExecutable="false">
          <bpmn:extensionElements><bfw:version>2.0.0</bfw:version></bpmn:extensionElements>
          <bpmn:startEvent id="S2"/>
        </bpmn:process>
      `);

      const result = parseBpmn(xml);
      expect(result.processes).toHaveLength(2);
      expect(result.processes[0]!.id).toBe('P1');
      expect(result.processes[0]!.isExecutable).toBe(true);
      expect(result.processes[1]!.id).toBe('P2');
      expect(result.processes[1]!.isExecutable).toBe(false);
    });
  });

  // -------------------------------------------------------------------------
  // Edge cases
  // -------------------------------------------------------------------------

  describe('edge cases', () => {
    it('returns empty definitions for XML without processes', () => {
      const xml = wrap('');
      const result = parseBpmn(xml);
      expect(result.processes).toHaveLength(0);
      expect(result.messages).toHaveLength(0);
    });

    it('returns empty result for XML without definitions', () => {
      const xml = '<?xml version="1.0" encoding="UTF-8"?><root/>';
      const result = parseBpmn(xml);
      expect(result.processes).toHaveLength(0);
      expect(result.definitionsId).toBeNull();
    });

    it('ignores unknown elements silently', () => {
      const xml = processWrap(
        'P',
        `
        <bpmn:startEvent id="S1"/>
        <bpmn:unknownElement id="X1" name="ignored"/>
        <bpmn:endEvent id="E1"/>
      `,
      );
      const result = parseBpmn(xml);
      expect(result.processes[0]!.flowNodes).toHaveLength(2);
    });

    it('sets isExecutable to true by default', () => {
      const xml = wrap(`
        <bpmn:process id="P">
          <bpmn:extensionElements><bfw:version>1.0.0</bfw:version></bpmn:extensionElements>
          <bpmn:startEvent id="S1"/>
        </bpmn:process>
      `);
      const result = parseBpmn(xml);
      expect(result.processes[0]!.isExecutable).toBe(true);
    });

    it('handles conditionExpression on sequence flow', () => {
      const xml = processWrap(
        'P',
        `
        <bpmn:startEvent id="S1"/>
        <bpmn:endEvent id="E1"/>
        <bpmn:sequenceFlow id="F1" sourceRef="S1" targetRef="E1">
          <bpmn:conditionExpression>token.amount > 100</bpmn:conditionExpression>
        </bpmn:sequenceFlow>
      `,
      );
      const result = parseBpmn(xml);
      expect(result.processes[0]!.sequenceFlows[0]!.conditionExpression).toBe('token.amount > 100');
    });

    it('parses incoming and outgoing refs', () => {
      const xml = processWrap(
        'P',
        `
        <bpmn:startEvent id="S1">
          <bpmn:outgoing>F1</bpmn:outgoing>
        </bpmn:startEvent>
        <bpmn:endEvent id="E1">
          <bpmn:incoming>F1</bpmn:incoming>
        </bpmn:endEvent>
        <bpmn:sequenceFlow id="F1" sourceRef="S1" targetRef="E1"/>
      `,
      );
      const result = parseBpmn(xml);
      expect(result.processes[0]!.flowNodes[0]!.outgoing).toEqual(['F1']);
      expect(result.processes[0]!.flowNodes[1]!.incoming).toEqual(['F1']);
    });

    it('parses documentation on flow nodes', () => {
      const xml = processWrap(
        'P',
        `
        <bpmn:task id="T1" name="Documented">
          <bpmn:documentation>This explains the task</bpmn:documentation>
        </bpmn:task>
      `,
      );
      const result = parseBpmn(xml);
      expect(result.processes[0]!.flowNodes[0]!.documentation).toBe('This explains the task');
    });
  });

  // -------------------------------------------------------------------------
  // Flow node types
  // -------------------------------------------------------------------------

  describe('flow node types', () => {
    it('parses all gateway types', () => {
      const xml = processWrap(
        'P',
        `
        <bpmn:exclusiveGateway id="XOR"/>
        <bpmn:parallelGateway id="AND"/>
        <bpmn:inclusiveGateway id="OR"/>
        <bpmn:eventBasedGateway id="EVT"/>
        <bpmn:complexGateway id="CX"/>
      `,
      );
      const result = parseBpmn(xml);
      const types = result.processes[0]!.flowNodes.map((node) => node.type);
      expect(types).toEqual([
        'exclusive_gateway',
        'parallel_gateway',
        'inclusive_gateway',
        'event_based_gateway',
        'complex_gateway',
      ]);
    });

    it('parses all activity types', () => {
      const xml = processWrap(
        'P',
        `
        <bpmn:task id="T1"/>
        <bpmn:userTask id="UT1"/>
        <bpmn:serviceTask id="ST1"/>
        <bpmn:manualTask id="MT1"/>
        <bpmn:scriptTask id="SCT1"/>
        <bpmn:businessRuleTask id="BRT1"/>
        <bpmn:sendTask id="SEND1"/>
        <bpmn:receiveTask id="RCV1"/>
        <bpmn:callActivity id="CA1" calledElement="Child"/>
        <bpmn:subProcess id="SP1"/>
      `,
      );
      const result = parseBpmn(xml);
      const types = result.processes[0]!.flowNodes.map((node) => node.type);
      expect(types).toEqual([
        'task',
        'user_task',
        'service_task',
        'manual_task',
        'script_task',
        'business_rule_task',
        'send_task',
        'receive_task',
        'call_activity',
        'sub_process',
      ]);
    });
  });

  // -------------------------------------------------------------------------
  // Default flows
  // -------------------------------------------------------------------------

  describe('default flows', () => {
    it('sets defaultFlowRef on exclusive gateway and isDefault on flow', () => {
      const xml = processWrap(
        'P',
        `
        <bpmn:startEvent id="S1"/>
        <bpmn:exclusiveGateway id="XOR" default="F_Default"/>
        <bpmn:endEvent id="E1"/>
        <bpmn:endEvent id="E2"/>
        <bpmn:sequenceFlow id="F1" sourceRef="S1" targetRef="XOR"/>
        <bpmn:sequenceFlow id="F_Cond" sourceRef="XOR" targetRef="E1">
          <bpmn:conditionExpression>token.ok</bpmn:conditionExpression>
        </bpmn:sequenceFlow>
        <bpmn:sequenceFlow id="F_Default" sourceRef="XOR" targetRef="E2"/>
      `,
      );

      const result = parseBpmn(xml);
      const xor = result.processes[0]!.flowNodes.find((node) => node.id === 'XOR')!;
      expect((xor.typeData as ExclusiveGatewayTypeData).defaultFlowRef).toBe('F_Default');

      const defaultFlow = result.processes[0]!.sequenceFlows.find((flow) => flow.id === 'F_Default')!;
      expect(defaultFlow.isDefault).toBe(true);

      const condFlow = result.processes[0]!.sequenceFlows.find((flow) => flow.id === 'F_Cond')!;
      expect(condFlow.isDefault).toBe(false);
    });
  });

  // -------------------------------------------------------------------------
  // Boundary events
  // -------------------------------------------------------------------------

  describe('boundary events', () => {
    it('links boundary event refs to host activity', () => {
      const xml = processWrap(
        'P',
        `
        <bpmn:serviceTask id="ST1" name="Host" implementation="echo">
        </bpmn:serviceTask>
        <bpmn:boundaryEvent id="BE1" attachedToRef="ST1">
          <bpmn:errorEventDefinition>
            <bpmn:extensionElements>
              <bfw:errorCode>FAIL</bfw:errorCode>
            </bpmn:extensionElements>
          </bpmn:errorEventDefinition>
        </bpmn:boundaryEvent>
        <bpmn:endEvent id="E1"/>
      `,
      );

      const result = parseBpmn(xml);
      const host = result.processes[0]!.flowNodes.find((node) => node.id === 'ST1')!;
      expect(host.boundaryEventRefs).toEqual(['BE1']);

      const boundary = result.processes[0]!.flowNodes.find((node) => node.id === 'BE1')!;
      const typeData = boundary.typeData as BoundaryEventTypeData;
      expect(typeData.attachedToRef).toBe('ST1');
      expect(typeData.cancelActivity).toBe(true);

      const errorDef = typeData.eventDefinition as ErrorEventDefinition;
      expect(errorDef.errorCode).toBe('FAIL');
    });

    it('sets cancelActivity to false for non-interrupting', () => {
      const xml = processWrap(
        'P',
        `
        <bpmn:task id="T1"/>
        <bpmn:boundaryEvent id="BE1" attachedToRef="T1" cancelActivity="false">
          <bpmn:timerEventDefinition>
            <bpmn:timeDuration>PT5M</bpmn:timeDuration>
          </bpmn:timerEventDefinition>
        </bpmn:boundaryEvent>
      `,
      );

      const result = parseBpmn(xml);
      const boundary = result.processes[0]!.flowNodes.find((node) => node.id === 'BE1')!;
      expect((boundary.typeData as BoundaryEventTypeData).cancelActivity).toBe(false);
    });
  });

  // -------------------------------------------------------------------------
  // Event definitions
  // -------------------------------------------------------------------------

  describe('event definitions', () => {
    it('parses message event definition', () => {
      const xml = wrap(`
        <bpmn:message id="Msg_1" name="OrderReceived"/>
        <bpmn:process id="P" isExecutable="true">
          <bpmn:extensionElements><bfw:version>1.0.0</bfw:version></bpmn:extensionElements>
          <bpmn:startEvent id="S1">
            <bpmn:messageEventDefinition messageRef="Msg_1">
              <bpmn:extensionElements>
                <bfw:correlationRetrievalExpression>payload.orderId</bfw:correlationRetrievalExpression>
                <bfw:payload>{ orderId: token.orderId }</bfw:payload>
                <bfw:eventMapping>{ order: event }</bfw:eventMapping>
              </bpmn:extensionElements>
            </bpmn:messageEventDefinition>
          </bpmn:startEvent>
        </bpmn:process>
      `);

      const result = parseBpmn(xml);
      const def = result.processes[0]!.flowNodes[0]!.typeData as {
        eventDefinition: MessageEventDefinition;
      };
      expect(def.eventDefinition.messageRef).toBe('Msg_1');
      expect(def.eventDefinition.correlationRetrievalExpression).toBe('payload.orderId');
      expect(def.eventDefinition).not.toHaveProperty('payloadExpression');
      expect(def.eventDefinition).not.toHaveProperty('eventMapping');
    });

    it('message event definition no longer carries payloadContract', () => {
      const xml = wrap(`
        <bpmn:message id="Msg_1" name="OrderReceived"/>
        <bpmn:process id="P" isExecutable="true">
          <bpmn:extensionElements><bfw:version>1.0.0</bfw:version></bpmn:extensionElements>
          <bpmn:intermediateCatchEvent id="Catch_1">
            <bpmn:messageEventDefinition messageRef="Msg_1">
              <bpmn:extensionElements>
                <bfw:correlationRetrievalExpression>payload.id</bfw:correlationRetrievalExpression>
              </bpmn:extensionElements>
            </bpmn:messageEventDefinition>
          </bpmn:intermediateCatchEvent>
        </bpmn:process>
      `);

      const result = parseBpmn(xml);
      const def = result.processes[0]!.flowNodes[0]!.typeData as IntermediateCatchEventTypeData;
      expect(def.eventDefinition).not.toHaveProperty('payloadContract');
    });

    it('parses resultContract on intermediate catch event at flow-node level', () => {
      const xml = wrap(`
        <bpmn:message id="Msg_1" name="OrderReceived"/>
        <bpmn:process id="P" isExecutable="true">
          <bpmn:extensionElements><bfw:version>1.0.0</bfw:version></bpmn:extensionElements>
          <bpmn:intermediateCatchEvent id="Catch_1">
            <bpmn:extensionElements>
              <bfw:resultContract>{"type":"object","required":["orderId"]}</bfw:resultContract>
            </bpmn:extensionElements>
            <bpmn:messageEventDefinition messageRef="Msg_1"/>
          </bpmn:intermediateCatchEvent>
        </bpmn:process>
      `);

      const result = parseBpmn(xml);
      const typeData = result.processes[0]!.flowNodes[0]!.typeData as IntermediateCatchEventTypeData;
      expect(typeData.resultContract).toEqual({ type: 'object', required: ['orderId'] });
    });

    it('parses payloadContract on intermediate throw event at flow-node level', () => {
      const xml = wrap(`
        <bpmn:message id="Msg_1" name="OrderReceived"/>
        <bpmn:process id="P" isExecutable="true">
          <bpmn:extensionElements><bfw:version>1.0.0</bfw:version></bpmn:extensionElements>
          <bpmn:intermediateThrowEvent id="Throw_1">
            <bpmn:extensionElements>
              <bfw:payloadContract>{"type":"object","required":["amount"]}</bfw:payloadContract>
            </bpmn:extensionElements>
            <bpmn:messageEventDefinition messageRef="Msg_1"/>
          </bpmn:intermediateThrowEvent>
        </bpmn:process>
      `);

      const result = parseBpmn(xml);
      const typeData = result.processes[0]!.flowNodes[0]!.typeData as IntermediateThrowEventTypeData;
      expect(typeData.payloadContract).toEqual({ type: 'object', required: ['amount'] });
    });

    it('parses payloadContract on end event at flow-node level', () => {
      const xml = wrap(`
        <bpmn:message id="Msg_1" name="OrderReceived"/>
        <bpmn:process id="P" isExecutable="true">
          <bpmn:extensionElements><bfw:version>1.0.0</bfw:version></bpmn:extensionElements>
          <bpmn:startEvent id="S1"><bpmn:outgoing>F1</bpmn:outgoing></bpmn:startEvent>
          <bpmn:endEvent id="E1">
            <bpmn:extensionElements>
              <bfw:payloadContract>{"type":"object","required":["total"]}</bfw:payloadContract>
            </bpmn:extensionElements>
            <bpmn:messageEventDefinition messageRef="Msg_1"/>
            <bpmn:incoming>F1</bpmn:incoming>
          </bpmn:endEvent>
          <bpmn:sequenceFlow id="F1" sourceRef="S1" targetRef="E1"/>
        </bpmn:process>
      `);

      const result = parseBpmn(xml);
      const typeData = result.processes[0]!.flowNodes[1]!.typeData as EndEventTypeData;
      expect(typeData.payloadContract).toEqual({ type: 'object', required: ['total'] });
    });

    it('parses resultContract on boundary event at flow-node level', () => {
      const xml = wrap(`
        <bpmn:message id="Msg_1" name="test"/>
        <bpmn:process id="P" isExecutable="true">
          <bpmn:extensionElements><bfw:version>1.0.0</bfw:version></bpmn:extensionElements>
          <bpmn:userTask id="UT1"/>
          <bpmn:boundaryEvent id="B1" attachedToRef="UT1">
            <bpmn:extensionElements>
              <bfw:resultContract>{"type":"object","required":["status"]}</bfw:resultContract>
            </bpmn:extensionElements>
            <bpmn:messageEventDefinition messageRef="Msg_1"/>
          </bpmn:boundaryEvent>
        </bpmn:process>
      `);

      const result = parseBpmn(xml);
      const boundary = result.processes[0]!.flowNodes.find((node) => node.id === 'B1');
      const typeData = boundary!.typeData as BoundaryEventTypeData;
      expect(typeData.resultContract).toEqual({ type: 'object', required: ['status'] });
    });

    it('parses resultContract on start event at flow-node level', () => {
      const xml = wrap(`
        <bpmn:message id="Msg_1" name="OrderStart"/>
        <bpmn:process id="P" isExecutable="true">
          <bpmn:extensionElements><bfw:version>1.0.0</bfw:version></bpmn:extensionElements>
          <bpmn:startEvent id="S1">
            <bpmn:extensionElements>
              <bfw:resultContract>{"type":"object","required":["orderId"]}</bfw:resultContract>
            </bpmn:extensionElements>
            <bpmn:messageEventDefinition messageRef="Msg_1"/>
          </bpmn:startEvent>
        </bpmn:process>
      `);

      const result = parseBpmn(xml);
      const typeData = result.processes[0]!.flowNodes[0]!.typeData as StartEventTypeData;
      expect(typeData.resultContract).toEqual({ type: 'object', required: ['orderId'] });
    });

    it('parses payloadContract on send task at flow-node level', () => {
      const xml = wrap(`
        <bpmn:message id="Msg_1" name="test"/>
        <bpmn:process id="P" isExecutable="true">
          <bpmn:extensionElements><bfw:version>1.0.0</bfw:version></bpmn:extensionElements>
          <bpmn:sendTask id="ST1" messageRef="Msg_1">
            <bpmn:extensionElements>
              <bfw:payloadContract>{"type":"object","required":["payload"]}</bfw:payloadContract>
            </bpmn:extensionElements>
          </bpmn:sendTask>
        </bpmn:process>
      `);

      const result = parseBpmn(xml);
      const typeData = result.processes[0]!.flowNodes[0]!.typeData as SendTaskTypeData;
      expect(typeData.payloadContract).toEqual({ type: 'object', required: ['payload'] });
    });

    it('parses resultContract on receive task at flow-node level', () => {
      const xml = wrap(`
        <bpmn:message id="Msg_1" name="test"/>
        <bpmn:process id="P" isExecutable="true">
          <bpmn:extensionElements><bfw:version>1.0.0</bfw:version></bpmn:extensionElements>
          <bpmn:receiveTask id="RT1" messageRef="Msg_1">
            <bpmn:extensionElements>
              <bfw:resultContract>{"type":"object","required":["result"]}</bfw:resultContract>
            </bpmn:extensionElements>
          </bpmn:receiveTask>
        </bpmn:process>
      `);

      const result = parseBpmn(xml);
      const typeData = result.processes[0]!.flowNodes[0]!.typeData as ReceiveTaskTypeData;
      expect(typeData.resultContract).toEqual({ type: 'object', required: ['result'] });
    });

    it('parses signal event definition', () => {
      const xml = wrap(`
        <bpmn:signal id="Sig_1" name="Done"/>
        <bpmn:process id="P" isExecutable="true">
          <bpmn:extensionElements><bfw:version>1.0.0</bfw:version></bpmn:extensionElements>
          <bpmn:endEvent id="E1">
            <bpmn:signalEventDefinition signalRef="Sig_1"/>
          </bpmn:endEvent>
        </bpmn:process>
      `);

      const result = parseBpmn(xml);
      const def = result.processes[0]!.flowNodes[0]!.typeData as {
        eventDefinition: SignalEventDefinition;
      };
      expect(def.eventDefinition.signalRef).toBe('Sig_1');
    });

    it('parses timer event definition with duration', () => {
      const xml = processWrap(
        'P',
        `
        <bpmn:intermediateCatchEvent id="ICE_1">
          <bpmn:timerEventDefinition>
            <bpmn:timeDuration>PT30M</bpmn:timeDuration>
          </bpmn:timerEventDefinition>
        </bpmn:intermediateCatchEvent>
      `,
      );

      const result = parseBpmn(xml);
      const def = result.processes[0]!.flowNodes[0]!.typeData as {
        eventDefinition: TimerEventDefinition;
      };
      expect(def.eventDefinition.timeDuration).toBe('PT30M');
      expect(def.eventDefinition.timeDate).toBeNull();
      expect(def.eventDefinition.timeCycle).toBeNull();
    });

    it('parses error event definition with code and message', () => {
      const xml = processWrap(
        'P',
        `
        <bpmn:task id="T1"/>
        <bpmn:boundaryEvent id="BE1" attachedToRef="T1">
          <bpmn:errorEventDefinition errorRef="Err_1">
            <bpmn:extensionElements>
              <bfw:errorCode>CUSTOM_ERROR</bfw:errorCode>
              <bfw:errorMessage>Something went wrong</bfw:errorMessage>
            </bpmn:extensionElements>
          </bpmn:errorEventDefinition>
        </bpmn:boundaryEvent>
      `,
      );

      const result = parseBpmn(xml);
      const boundary = result.processes[0]!.flowNodes.find((node) => node.id === 'BE1')!;
      const def = (boundary.typeData as BoundaryEventTypeData).eventDefinition as ErrorEventDefinition;
      expect(def.errorRef).toBe('Err_1');
      expect(def.errorCode).toBe('CUSTOM_ERROR');
      expect(def.errorMessage).toBe('Something went wrong');
    });

    it('parses escalation event definition', () => {
      const xml = wrap(`
        <bpmn:escalation id="Esc_1" name="Review" escalationCode="ESC_1"/>
        <bpmn:process id="P" isExecutable="true">
          <bpmn:extensionElements><bfw:version>1.0.0</bfw:version></bpmn:extensionElements>
          <bpmn:endEvent id="E1">
            <bpmn:escalationEventDefinition escalationRef="Esc_1"/>
          </bpmn:endEvent>
        </bpmn:process>
      `);

      const result = parseBpmn(xml);
      const def = result.processes[0]!.flowNodes[0]!.typeData as {
        eventDefinition: EscalationEventDefinition;
      };
      expect(def.eventDefinition.escalationRef).toBe('Esc_1');
    });

    it('parses link event definition', () => {
      const xml = processWrap(
        'P',
        `
        <bpmn:intermediateThrowEvent id="LT1">
          <bpmn:linkEventDefinition name="GoToSection2"/>
        </bpmn:intermediateThrowEvent>
        <bpmn:intermediateCatchEvent id="LC1">
          <bpmn:linkEventDefinition name="GoToSection2"/>
        </bpmn:intermediateCatchEvent>
      `,
      );

      const result = parseBpmn(xml);
      const throwDef = result.processes[0]!.flowNodes[0]!.typeData as {
        eventDefinition: LinkEventDefinition;
      };
      expect(throwDef.eventDefinition.linkName).toBe('GoToSection2');
    });

    it('parses compensation event definition', () => {
      const xml = processWrap(
        'P',
        `
        <bpmn:endEvent id="E1">
          <bpmn:compensateEventDefinition activityRef="T1" waitForCompletion="false"/>
        </bpmn:endEvent>
      `,
      );

      const result = parseBpmn(xml);
      const def = result.processes[0]!.flowNodes[0]!.typeData as {
        eventDefinition: CompensationEventDefinition;
      };
      expect(def.eventDefinition.activityRef).toBe('T1');
      expect(def.eventDefinition.waitForCompletion).toBe(false);
    });

    it('uses none type for bare event definition', () => {
      const xml = processWrap('P', '<bpmn:startEvent id="S1"/>');
      const result = parseBpmn(xml);
      const typeData = result.processes[0]!.flowNodes[0]!.typeData as {
        eventDefinition: Record<string, unknown>;
      };
      expect(typeData.eventDefinition).toEqual({ type: 'none' });
    });
  });

  // -------------------------------------------------------------------------
  // bfw:* extensions — UserTask
  // -------------------------------------------------------------------------

  describe('bfw:* extensions — UserTask', () => {
    it('parses assignees, formFields, dueDate, priority', () => {
      const xml = processWrap(
        'P',
        `
        <bpmn:userTask id="UT1" name="Review">
          <bpmn:extensionElements>
            <bfw:assignees>identity.groups</bfw:assignees>
            <bfw:formFields>{"fields":[{"name":"ok","type":"boolean"}]}</bfw:formFields>
            <bfw:dueDate>2026-12-31T23:59:59Z</bfw:dueDate>
            <bfw:priority>5</bfw:priority>
          </bpmn:extensionElements>
        </bpmn:userTask>
      `,
      );

      const result = parseBpmn(xml);
      const typeData = result.processes[0]!.flowNodes[0]!.typeData as UserTaskTypeData;
      expect(typeData.assigneesExpression).toBe('identity.groups');
      expect(typeData.formSchema).toEqual({
        fields: [{ name: 'ok', type: 'boolean' }],
      });
      expect(typeData.dueDate).toBe('2026-12-31T23:59:59Z');
      expect(typeData.priority).toBe(5);
    });

    it('parses payloadContract and resultContract', () => {
      const xml = processWrap(
        'P',
        `
        <bpmn:userTask id="UT1">
          <bpmn:extensionElements>
            <bfw:payloadContract>{"type":"object","required":["name"]}</bfw:payloadContract>
            <bfw:resultContract>{"type":"object","required":["approved"]}</bfw:resultContract>
          </bpmn:extensionElements>
        </bpmn:userTask>
      `,
      );

      const result = parseBpmn(xml);
      const typeData = result.processes[0]!.flowNodes[0]!.typeData as UserTaskTypeData;
      expect(typeData.payloadContract).toEqual({
        type: 'object',
        required: ['name'],
      });
      expect(typeData.resultContract).toEqual({
        type: 'object',
        required: ['approved'],
      });
    });

    it('parses input and output mappings', () => {
      const xml = processWrap(
        'P',
        `
        <bpmn:userTask id="UT1">
          <bpmn:extensionElements>
            <bfw:inputMapping source="token.raw_name" target="name"/>
            <bfw:outputMapping source="token.approved" target="result"/>
          </bpmn:extensionElements>
        </bpmn:userTask>
      `,
      );

      const result = parseBpmn(xml);
      const typeData = result.processes[0]!.flowNodes[0]!.typeData as UserTaskTypeData;
      expect(typeData.inMappings).toEqual([{ source: 'token.raw_name', target: 'name' }]);
      expect(typeData.outMappings).toEqual([{ source: 'token.approved', target: 'result' }]);
    });
  });

  // -------------------------------------------------------------------------
  // bfw:* extensions — ServiceTask
  // -------------------------------------------------------------------------

  describe('bfw:* extensions — ServiceTask', () => {
    it('parses implementation from BPMN attribute', () => {
      const xml = processWrap(
        'P',
        `
        <bpmn:serviceTask id="ST1" implementation="echo"/>
      `,
      );

      const result = parseBpmn(xml);
      const typeData = result.processes[0]!.flowNodes[0]!.typeData as ServiceTaskTypeData;
      expect(typeData.implementation).toBe('echo');
    });

    it('parses HTTP handler extensions', () => {
      const xml = processWrap(
        'P',
        `
        <bpmn:serviceTask id="ST1" implementation="http">
          <bpmn:extensionElements>
            <bfw:httpUrl>https://api.example.com/v1/echo</bfw:httpUrl>
            <bfw:httpMethod>post</bfw:httpMethod>
            <bfw:httpBody>{ "message": token.message }</bfw:httpBody>
            <bfw:httpAuthHeader>"Bearer " + token.apiToken</bfw:httpAuthHeader>
            <bfw:httpResponseHeaders>response.headers</bfw:httpResponseHeaders>
          </bpmn:extensionElements>
        </bpmn:serviceTask>
      `,
      );

      const result = parseBpmn(xml);
      const typeData = result.processes[0]!.flowNodes[0]!.typeData as ServiceTaskTypeData;
      expect(typeData.httpUrl).toBe('https://api.example.com/v1/echo');
      expect(typeData.httpMethod).toBe('POST');
      expect(typeData.httpBody).toBe('{ "message": token.message }');
      expect(typeData.httpAuthHeader).toBe('"Bearer " + token.apiToken');
      expect(typeData.httpResponseHeaders).toBe('response.headers');
    });

    it('parses mappings and contracts on service task', () => {
      const xml = processWrap(
        'P',
        `
        <bpmn:serviceTask id="ST1" implementation="echo">
          <bpmn:extensionElements>
            <bfw:inputMapping source="token.order_id" target="id"/>
            <bfw:outputMapping source="token.input.id" target="result_id"/>
            <bfw:payloadContract>{"required":["id"],"type":"object"}</bfw:payloadContract>
            <bfw:resultContract>{"type":"object"}</bfw:resultContract>
          </bpmn:extensionElements>
        </bpmn:serviceTask>
      `,
      );

      const result = parseBpmn(xml);
      const typeData = result.processes[0]!.flowNodes[0]!.typeData as ServiceTaskTypeData;
      expect(typeData.inMappings).toEqual([{ source: 'token.order_id', target: 'id' }]);
      expect(typeData.outMappings).toEqual([{ source: 'token.input.id', target: 'result_id' }]);
      expect(typeData.payloadContract).toEqual({
        required: ['id'],
        type: 'object',
      });
    });
  });

  // -------------------------------------------------------------------------
  // bfw:* extensions — ManualTask
  // -------------------------------------------------------------------------

  describe('bfw:* extensions — ManualTask', () => {
    it('parses requireConfirmation', () => {
      const xml = processWrap(
        'P',
        `
        <bpmn:manualTask id="MT1">
          <bpmn:extensionElements>
            <bfw:requireConfirmation>true</bfw:requireConfirmation>
          </bpmn:extensionElements>
        </bpmn:manualTask>
      `,
      );

      const result = parseBpmn(xml);
      const typeData = result.processes[0]!.flowNodes[0]!.typeData as ManualTaskTypeData;
      expect(typeData.requireConfirmation).toBe(true);
    });

    it('defaults requireConfirmation to false', () => {
      const xml = processWrap('P', '<bpmn:manualTask id="MT1"/>');
      const result = parseBpmn(xml);
      const typeData = result.processes[0]!.flowNodes[0]!.typeData as ManualTaskTypeData;
      expect(typeData.requireConfirmation).toBe(false);
    });
  });

  // -------------------------------------------------------------------------
  // bfw:* extensions — ScriptTask
  // -------------------------------------------------------------------------

  describe('bfw:* extensions — ScriptTask', () => {
    it('parses inline script and scriptFormat', () => {
      const xml = processWrap(
        'P',
        `
        <bpmn:scriptTask id="SCT1" scriptFormat="feel">
          <bpmn:script>token.amount * 1.19</bpmn:script>
        </bpmn:scriptTask>
      `,
      );

      const result = parseBpmn(xml);
      const typeData = result.processes[0]!.flowNodes[0]!.typeData as ScriptTaskTypeData;
      expect(typeData.script).toBe('token.amount * 1.19');
      expect(typeData.scriptFormat).toBe('feel');
      expect(typeData.scriptRef).toBeNull();
    });

    it('parses bfw:scriptRef', () => {
      const xml = processWrap(
        'P',
        `
        <bpmn:scriptTask id="SCT1">
          <bpmn:extensionElements>
            <bfw:scriptRef>my_validator</bfw:scriptRef>
          </bpmn:extensionElements>
        </bpmn:scriptTask>
      `,
      );

      const result = parseBpmn(xml);
      const typeData = result.processes[0]!.flowNodes[0]!.typeData as ScriptTaskTypeData;
      expect(typeData.scriptRef).toBe('my_validator');
      expect(typeData.script).toBeNull();
    });
  });

  // -------------------------------------------------------------------------
  // bfw:* extensions — CallActivity
  // -------------------------------------------------------------------------

  describe('bfw:* extensions — CallActivity', () => {
    it('parses calledElement and mappings', () => {
      const xml = processWrap(
        'P',
        `
        <bpmn:callActivity id="CA1" calledElement="ChildProcess">
          <bpmn:extensionElements>
            <bfw:inputMapping source="token.orderId" target="orderId"/>
            <bfw:outputMapping source="result.trackingNumber" target="trackingNumber"/>
          </bpmn:extensionElements>
        </bpmn:callActivity>
      `,
      );

      const result = parseBpmn(xml);
      const typeData = result.processes[0]!.flowNodes[0]!.typeData as CallActivityTypeData;
      expect(typeData.calledElement).toBe('ChildProcess');
      expect(typeData.startEventId).toBeNull();
      expect(typeData.calledProcessVersion).toBeNull();
      expect(typeData.inMappings).toEqual([{ source: 'token.orderId', target: 'orderId' }]);
      expect(typeData.outMappings).toEqual([{ source: 'result.trackingNumber', target: 'trackingNumber' }]);
    });

    it('parses bfw:calledProcessVersion', () => {
      const xml = processWrap(
        'P',
        `
        <bpmn:callActivity id="CA1" calledElement="ChildProcess">
          <bpmn:extensionElements>
            <bfw:calledProcessVersion>1.2.0</bfw:calledProcessVersion>
          </bpmn:extensionElements>
        </bpmn:callActivity>
      `,
      );

      const result = parseBpmn(xml);
      const typeData = result.processes[0]!.flowNodes[0]!.typeData as CallActivityTypeData;
      expect(typeData.calledProcessVersion).toBe('1.2.0');
    });

    it('trims whitespace-only calledProcessVersion to null', () => {
      const xml = processWrap(
        'P',
        `
        <bpmn:callActivity id="CA1" calledElement="ChildProcess">
          <bpmn:extensionElements>
            <bfw:calledProcessVersion>   </bfw:calledProcessVersion>
          </bpmn:extensionElements>
        </bpmn:callActivity>
      `,
      );

      const result = parseBpmn(xml);
      const typeData = result.processes[0]!.flowNodes[0]!.typeData as CallActivityTypeData;
      expect(typeData.calledProcessVersion).toBeNull();
    });
  });

  // -------------------------------------------------------------------------
  // bfw:* extensions — correlationKey
  // -------------------------------------------------------------------------

  describe('bfw:* extensions — correlationKey', () => {
    it('parses correlationKey on process', () => {
      const xml = wrap(`
        <bpmn:process id="P" isExecutable="true">
          <bpmn:extensionElements>
            <bfw:version>1.0.0</bfw:version>
            <bfw:correlationKey>order.customerId</bfw:correlationKey>
          </bpmn:extensionElements>
          <bpmn:startEvent id="S1"/>
        </bpmn:process>
      `);

      const result = parseBpmn(xml);
      expect(result.processes[0]!.correlationKey).toBe('order.customerId');
    });
  });

  // -------------------------------------------------------------------------
  // Lanes
  // -------------------------------------------------------------------------

  describe('lanes', () => {
    it('parses lanes with flow node refs', () => {
      const xml = processWrap(
        'P',
        `
        <bpmn:laneSet>
          <bpmn:lane id="Lane_1" name="Clerk">
            <bpmn:flowNodeRef>T1</bpmn:flowNodeRef>
            <bpmn:flowNodeRef>T2</bpmn:flowNodeRef>
          </bpmn:lane>
        </bpmn:laneSet>
        <bpmn:task id="T1"/>
        <bpmn:task id="T2"/>
      `,
      );

      const result = parseBpmn(xml);
      expect(result.processes[0]!.lanes).toHaveLength(1);
      expect(result.processes[0]!.lanes[0]).toEqual({
        id: 'Lane_1',
        name: 'Clerk',
        flowNodeRefs: ['T1', 'T2'],
      });
    });
  });

  // -------------------------------------------------------------------------
  // Data objects and associations
  // -------------------------------------------------------------------------

  describe('data objects and associations', () => {
    it('parses data objects and references', () => {
      const xml = processWrap(
        'P',
        `
        <bpmn:dataObject id="DO_1" name="OrderData"/>
        <bpmn:dataObjectReference id="DOR_1" dataObjectRef="DO_1"/>
        <bpmn:startEvent id="S1"/>
      `,
      );

      const result = parseBpmn(xml);
      expect(result.processes[0]!.dataObjects).toHaveLength(1);
      expect(result.processes[0]!.dataObjects[0]!.id).toBe('DO_1');
      expect(result.processes[0]!.dataObjects[0]!.name).toBe('OrderData');

      expect(result.processes[0]!.dataObjectReferences).toHaveLength(1);
      expect(result.processes[0]!.dataObjectReferences[0]!.dataObjectRef).toBe('DO_1');
    });

    it('parses data output associations on flow nodes', () => {
      const xml = processWrap(
        'P',
        `
        <bpmn:scriptTask id="SCT1">
          <bpmn:dataOutputAssociation id="DOA_1">
            <bpmn:targetRef>DOR_1</bpmn:targetRef>
          </bpmn:dataOutputAssociation>
        </bpmn:scriptTask>
      `,
      );

      const result = parseBpmn(xml);
      const node = result.processes[0]!.flowNodes[0]!;
      expect(node.dataOutputAssociations).toHaveLength(1);
      expect(node.dataOutputAssociations[0]!.id).toBe('DOA_1');
      expect(node.dataOutputAssociations[0]!.targetRef).toBe('DOR_1');
    });

    it('parses bfw:valueContract on data object', () => {
      const xml = processWrap(
        'P',
        `
        <bpmn:dataObject id="DO_1" name="StrictData">
          <bpmn:extensionElements>
            <bfw:valueContract>{"type":"object","required":["name"]}</bfw:valueContract>
          </bpmn:extensionElements>
        </bpmn:dataObject>
        <bpmn:startEvent id="S1"/>
      `,
      );

      const result = parseBpmn(xml);
      expect(result.processes[0]!.dataObjects[0]!.valueContract).toEqual({
        type: 'object',
        required: ['name'],
      });
    });
  });

  // -------------------------------------------------------------------------
  // Multi-instance
  // -------------------------------------------------------------------------

  describe('multi-instance', () => {
    it('parses multi-instance with evil extensions', () => {
      const xml = processWrap(
        'P',
        `
        <bpmn:task id="T1">
          <bpmn:multiInstanceLoopCharacteristics isSequential="true">
            <bpmn:loopCardinality>5</bpmn:loopCardinality>
            <bpmn:completionCondition>done</bpmn:completionCondition>
            <bpmn:extensionElements>
              <bfw:inputCollection>token.items</bfw:inputCollection>
              <bfw:outputCollection>processedItems</bfw:outputCollection>
              <bfw:loopBreakCondition>errorCount > 3</bfw:loopBreakCondition>
              <bfw:loopInterval>PT1S</bfw:loopInterval>
              <bfw:maxIterations>100</bfw:maxIterations>
            </bpmn:extensionElements>
          </bpmn:multiInstanceLoopCharacteristics>
        </bpmn:task>
      `,
      );

      const result = parseBpmn(xml);
      const mi = result.processes[0]!.flowNodes[0]!.multiInstance!;
      expect(mi.isSequential).toBe(true);
      expect(mi.completionCondition).toBe('done');
      expect(mi.collectionExpression).toBe('token.items');
      expect(mi.outputCollection).toBe('processedItems');
      expect(mi.loopBreakCondition).toBe('errorCount > 3');
      expect(mi.loopInterval).toBe('PT1S');
      expect(mi.maxIterations).toBe(100);
      expect(mi.loopCardinality).toBe('5');
    });
  });

  // -------------------------------------------------------------------------
  // Data contracts
  // -------------------------------------------------------------------------

  describe('data contracts', () => {
    it('parses bfw:dataContract on flow node', () => {
      const xml = processWrap(
        'P',
        `
        <bpmn:task id="T1">
          <bpmn:extensionElements>
            <bfw:dataContract>{"direction":"input","schema":{"type":"object","required":["orderId"]}}</bfw:dataContract>
          </bpmn:extensionElements>
        </bpmn:task>
      `,
      );

      const result = parseBpmn(xml);
      expect(result.processes[0]!.flowNodes[0]!.dataContracts).toHaveLength(1);
      const contract = result.processes[0]!.flowNodes[0]!.dataContracts[0]!;
      expect(contract.direction).toBe('input');
      expect(contract.jsonSchema).toEqual({
        type: 'object',
        required: ['orderId'],
      });
      expect(contract.compiledSchema).toBeNull();
    });
  });

  // -------------------------------------------------------------------------
  // Elixir parity — fields and orderings the conformance corpus pins down.
  // These assert the *intent* behind each rule so a failure names the contract
  // rather than dumping a 400-line snapshot diff.
  // -------------------------------------------------------------------------

  describe('Elixir parity', () => {
    it('keeps incoming and outgoing in reverse document order', () => {
      const xml = processWrap(
        'P',
        `
        <bpmn:task id="T1">
          <bpmn:incoming>In_A</bpmn:incoming>
          <bpmn:incoming>In_B</bpmn:incoming>
          <bpmn:outgoing>Out_A</bpmn:outgoing>
          <bpmn:outgoing>Out_B</bpmn:outgoing>
        </bpmn:task>
      `,
      );

      const flowNode = parseBpmn(xml).processes[0]!.flowNodes[0]!;
      expect(flowNode.incoming).toEqual(['In_B', 'In_A']);
      expect(flowNode.outgoing).toEqual(['Out_B', 'Out_A']);
    });

    it('flattens lanes from nested childLaneSet, innermost first', () => {
      const xml = processWrap(
        'P',
        `
        <bpmn:laneSet>
          <bpmn:lane id="Lane_Parent" name="Parent">
            <bpmn:flowNodeRef>T1</bpmn:flowNodeRef>
            <bpmn:childLaneSet>
              <bpmn:lane id="Lane_Child" name="Child">
                <bpmn:flowNodeRef>T2</bpmn:flowNodeRef>
              </bpmn:lane>
            </bpmn:childLaneSet>
          </bpmn:lane>
        </bpmn:laneSet>
        <bpmn:task id="T1"/>
        <bpmn:task id="T2"/>
      `,
      );

      const lanes = parseBpmn(xml).processes[0]!.lanes;
      expect(lanes.map((lane) => lane.id)).toEqual(['Lane_Child', 'Lane_Parent']);
    });

    it('hoists associations declared inside a subprocess to the process level', () => {
      const xml = processWrap(
        'P',
        `
        <bpmn:subProcess id="Sub_1">
          <bpmn:task id="Inner_Task"/>
          <bpmn:association id="Assoc_1" sourceRef="Inner_Task" targetRef="Inner_Handler" associationDirection="One"/>
        </bpmn:subProcess>
      `,
      );

      const associations = parseBpmn(xml).processes[0]!.associations;
      expect(associations).toEqual([
        {
          id: 'Assoc_1',
          sourceRef: 'Inner_Task',
          targetRef: 'Inner_Handler',
          associationDirection: 'One',
        },
      ]);
    });

    it('resolves compensationHandlerId from the boundary event association', () => {
      const xml = processWrap(
        'P',
        `
        <bpmn:task id="Task_Book"/>
        <bpmn:task id="Task_Undo" isForCompensation="true"/>
        <bpmn:boundaryEvent id="BE_Comp" attachedToRef="Task_Book" cancelActivity="false">
          <bpmn:compensateEventDefinition/>
        </bpmn:boundaryEvent>
        <bpmn:association id="Assoc_1" sourceRef="BE_Comp" targetRef="Task_Undo"/>
      `,
      );

      const process = parseBpmn(xml).processes[0]!;
      const boundary = process.flowNodes.find((node) => node.id === 'BE_Comp')!;
      const handler = process.flowNodes.find((node) => node.id === 'Task_Undo')!;

      expect((boundary.typeData as BoundaryEventTypeData).compensationHandlerId).toBe('Task_Undo');
      expect(handler.isForCompensation).toBe(true);
      expect(process.flowNodes.find((node) => node.id === 'Task_Book')!.isForCompensation).toBe(false);
    });

    it('stores loopCardinality text so deploy can reject it, matching the Elixir parser', () => {
      const xml = processWrap(
        'P',
        `
        <bpmn:task id="T1">
          <bpmn:multiInstanceLoopCharacteristics isSequential="true">
            <bpmn:loopCardinality>5</bpmn:loopCardinality>
          </bpmn:multiInstanceLoopCharacteristics>
        </bpmn:task>
      `,
      );

      const multiInstance = parseBpmn(xml).processes[0]!.flowNodes[0]!.multiInstance!;
      expect(multiInstance.isSequential).toBe(true);
      expect(multiInstance.loopCardinality).toBe('5');
    });

    it('treats blank loopCardinality as null', () => {
      const xml = processWrap(
        'P',
        `
        <bpmn:task id="T1">
          <bpmn:multiInstanceLoopCharacteristics>
            <bpmn:loopCardinality>   </bpmn:loopCardinality>
          </bpmn:multiInstanceLoopCharacteristics>
        </bpmn:task>
      `,
      );

      const multiInstance = parseBpmn(xml).processes[0]!.flowNodes[0]!.multiInstance!;
      expect(multiInstance.loopCardinality).toBeNull();
    });

    it('parses the complex gateway activation condition', () => {
      const xml = processWrap(
        'P',
        `
        <bpmn:complexGateway id="CG_1">
          <bpmn:activationCondition>activatedCount &gt;= 2</bpmn:activationCondition>
        </bpmn:complexGateway>
      `,
      );

      const typeData = parseBpmn(xml).processes[0]!.flowNodes[0]!.typeData as ComplexGatewayTypeData;
      expect(typeData.activationCondition).toBe('activatedCount >= 2');
    });

    it('parses the full BusinessRuleTask DMN field set', () => {
      const xml = processWrap(
        'P',
        `
        <bpmn:businessRuleTask id="BRT_1" implementation="dmn">
          <bpmn:extensionElements>
            <bfw:decisionRef>discount-rules</bfw:decisionRef>
            <bfw:decisionElementId>Decision_Risk</bfw:decisionElementId>
            <bfw:resultVariable>discount</bfw:resultVariable>
            <bfw:traceUnmatchedRules>true</bfw:traceUnmatchedRules>
            <bfw:inputMapping source="token.amount" target="amount"/>
            <bfw:outputMapping source="result.discount" target="discount"/>
            <bfw:resultContract>{"type":"object"}</bfw:resultContract>
          </bpmn:extensionElements>
        </bpmn:businessRuleTask>
      `,
      );

      const typeData = parseBpmn(xml).processes[0]!.flowNodes[0]!.typeData as BusinessRuleTaskTypeData;
      expect(typeData.implementation).toBe('dmn');
      expect(typeData.decisionRef).toBe('discount-rules');
      expect(typeData.decisionElementId).toBe('Decision_Risk');
      expect(typeData.resultVariable).toBe('discount');
      expect(typeData.traceUnmatchedRules).toBe(true);
      expect(typeData.inMappings).toEqual([{ source: 'token.amount', target: 'amount' }]);
      expect(typeData.outMappings).toEqual([{ source: 'result.discount', target: 'discount' }]);
      expect(typeData.resultContract).toEqual({ type: 'object' });
    });

    it('parses the inline FEEL script on a BusinessRuleTask', () => {
      const xml = processWrap(
        'P',
        `
        <bpmn:businessRuleTask id="BRT_1" implementation="feel">
          <bpmn:script>{ discount: 0.1 }</bpmn:script>
        </bpmn:businessRuleTask>
      `,
      );

      const typeData = parseBpmn(xml).processes[0]!.flowNodes[0]!.typeData as BusinessRuleTaskTypeData;
      expect(typeData.implementation).toBe('feel');
      expect(typeData.script).toBe('{ discount: 0.1 }');
      expect(typeData.decisionRef).toBeNull();
    });

    it('parses inMappings and outMappings on send and receive tasks', () => {
      const xml = processWrap(
        'P',
        `
        <bpmn:sendTask id="Send_1" messageRef="Msg_1">
          <bpmn:extensionElements>
            <bfw:inputMapping source="token.id" target="id"/>
          </bpmn:extensionElements>
        </bpmn:sendTask>
        <bpmn:receiveTask id="Receive_1" messageRef="Msg_1">
          <bpmn:extensionElements>
            <bfw:outputMapping source="event.ack" target="ack"/>
          </bpmn:extensionElements>
        </bpmn:receiveTask>
      `,
      );

      const nodes = parseBpmn(xml).processes[0]!.flowNodes;
      const send = nodes.find((node) => node.id === 'Send_1')!.typeData as SendTaskTypeData;
      const receive = nodes.find((node) => node.id === 'Receive_1')!.typeData as ReceiveTaskTypeData;

      expect(send.inMappings).toEqual([{ source: 'token.id', target: 'id' }]);
      expect(receive.outMappings).toEqual([{ source: 'event.ack', target: 'ack' }]);
    });

    it('applies BPMN defaults for an ad-hoc subprocess', () => {
      const xml = processWrap('P', `<bpmn:adHocSubProcess id="AdHoc_1"><bpmn:task id="T1"/></bpmn:adHocSubProcess>`);

      const typeData = parseBpmn(xml).processes[0]!.flowNodes[0]!.typeData as SubProcessTypeData;
      expect(typeData.isAdHoc).toBe(true);
      expect(typeData.adhocOrdering).toBe('parallel');
      expect(typeData.cancelRemainingInstances).toBe(true);
      expect(typeData.adhocCompletionCondition).toBeNull();
    });

    it('honours explicit ad-hoc ordering and cancelRemainingInstances=false', () => {
      const xml = processWrap(
        'P',
        `
        <bpmn:adHocSubProcess id="AdHoc_1" ordering="Sequential" cancelRemainingInstances="false">
          <bpmn:task id="T1"/>
          <bpmn:completionCondition>performedActivities &gt; 1</bpmn:completionCondition>
        </bpmn:adHocSubProcess>
      `,
      );

      const typeData = parseBpmn(xml).processes[0]!.flowNodes[0]!.typeData as SubProcessTypeData;
      expect(typeData.adhocOrdering).toBe('sequential');
      expect(typeData.cancelRemainingInstances).toBe(false);
      expect(typeData.adhocCompletionCondition).toBe('performedActivities > 1');
    });

    it('marks a transaction subprocess and leaves the enclosing process unscoped', () => {
      const xml = processWrap(
        'P',
        `<bpmn:transaction id="Tx_1" method="##Compensate"><bpmn:task id="T1"/></bpmn:transaction>`,
      );

      const process = parseBpmn(xml).processes[0]!;
      const typeData = process.flowNodes[0]!.typeData as SubProcessTypeData;

      expect(typeData.isTransaction).toBe(true);
      expect(typeData.transactionMethod).toBe('##Compensate');
      // The scope flags describe the process a node lives *in*, so a top-level
      // process is never itself a transaction or ad-hoc scope.
      expect(process.isTransactionScope).toBe(false);
      expect(process.isAdHocScope).toBe(false);
    });
  });
});
