import { describe, expect, it } from 'vitest';
import {
  EVENT_DEFINITION_FRAGMENTS,
  FLOW_NODE_COMMON_FIELDS,
  FLOW_NODE_TYPE_FIELDS,
  buildFlowNodeSelection,
  buildProcessModelSelection,
  type SelectionField,
} from '../../src/graphql/model-fields.js';

const NODE_TYPE_NAMES = [
  'TaskNode',
  'UserTaskNode',
  'ServiceTaskNode',
  'ManualTaskNode',
  'ScriptTaskNode',
  'BusinessRuleTaskNode',
  'SendTaskNode',
  'ReceiveTaskNode',
  'CallActivityNode',
  'SubProcessNode',
  'ExclusiveGatewayNode',
  'ParallelGatewayNode',
  'InclusiveGatewayNode',
  'EventBasedGatewayNode',
  'ComplexGatewayNode',
  'UnknownNode',
  'StartEventNode',
  'EndEventNode',
  'IntermediateCatchEventNode',
  'IntermediateThrowEventNode',
  'BoundaryEventNode',
];

const EVENT_DEFINITION_TYPE_NAMES = [
  'NoneEventDefinition',
  'MessageEventDefinition',
  'SignalEventDefinition',
  'TimerEventDefinition',
  'ErrorEventDefinition',
  'EscalationEventDefinition',
  'ConditionalEventDefinition',
  'CompensationEventDefinition',
  'TerminateEventDefinition',
  'CancelEventDefinition',
  'LinkEventDefinition',
];

function fieldNames(fields: SelectionField[]): string[] {
  return fields.map((field) => (typeof field === 'string' ? field : field.name));
}

describe('FLOW_NODE_TYPE_FIELDS', () => {
  it('covers all 21 concrete FlowNode types, one per FlowNodeData struct', () => {
    expect(Object.keys(FLOW_NODE_TYPE_FIELDS).sort()).toEqual([...NODE_TYPE_NAMES].sort());
  });
});

describe('EVENT_DEFINITION_FRAGMENTS', () => {
  it('covers all 11 concrete EventDefinition union members', () => {
    expect(Object.keys(EVENT_DEFINITION_FRAGMENTS).sort()).toEqual([...EVENT_DEFINITION_TYPE_NAMES].sort());
  });
});

describe('buildFlowNodeSelection', () => {
  it('selects the flowNode field with common fields and a fragment per node type', () => {
    const selection = buildFlowNodeSelection();

    expect(selection.name).toBe('flowNode');
    expect(fieldNames(selection.fields ?? [])).toEqual(fieldNames(FLOW_NODE_COMMON_FIELDS));
    expect(Object.keys(selection.on ?? {}).sort()).toEqual([...NODE_TYPE_NAMES].sort());
  });

  it('omits nested flowNodes on SubProcessNode at depth 0', () => {
    const selection = buildFlowNodeSelection(0);
    const subProcessFields = selection.on?.['SubProcessNode'] ?? [];
    expect(fieldNames(subProcessFields)).not.toContain('flowNodes');
  });

  it('adds nested flowNodes on SubProcessNode when depth > 0', () => {
    const selection = buildFlowNodeSelection(1);
    const subProcessFields = selection.on?.['SubProcessNode'] ?? [];
    expect(fieldNames(subProcessFields)).toContain('flowNodes');

    const nestedFlowNodes = subProcessFields.find(
      (field): field is { name: string; fields?: SelectionField[]; on?: Record<string, SelectionField[]> } =>
        typeof field !== 'string' && field.name === 'flowNodes',
    );
    expect(nestedFlowNodes).toBeDefined();
    // One level of depth remaining means the nested SubProcessNode fragment
    // must not recurse further.
    const nestedSubProcessFields = nestedFlowNodes?.on?.['SubProcessNode'] ?? [];
    expect(fieldNames(nestedSubProcessFields)).not.toContain('flowNodes');
  });

  it('includes outMappings on SendTaskNode', () => {
    const selection = buildFlowNodeSelection();
    const sendTaskFields = selection.on?.['SendTaskNode'] ?? [];
    expect(fieldNames(sendTaskFields)).toContain('inMappings');
    expect(fieldNames(sendTaskFields)).toContain('outMappings');
  });

  it('includes eventDefinition inline fragments on every event-position node type', () => {
    const selection = buildFlowNodeSelection();
    for (const eventNodeType of [
      'StartEventNode',
      'EndEventNode',
      'IntermediateCatchEventNode',
      'IntermediateThrowEventNode',
      'BoundaryEventNode',
    ]) {
      const fields = selection.on?.[eventNodeType] ?? [];
      const eventDefinitionField = fields.find(
        (field): field is { name: string; on?: Record<string, SelectionField[]> } =>
          typeof field !== 'string' && field.name === 'eventDefinition',
      );
      expect(eventDefinitionField).toBeDefined();
      expect(Object.keys(eventDefinitionField?.on ?? {}).sort()).toEqual([...EVENT_DEFINITION_TYPE_NAMES].sort());
    }
  });
});

describe('buildProcessModelSelection', () => {
  it('selects processModel scalar fields plus flowNodes and allFlowNodes', () => {
    const selection = buildProcessModelSelection(2);
    const names = fieldNames(selection.fields ?? []);

    expect(selection.name).toBe('processModel');
    expect(names).toContain('id');
    expect(names).toContain('isTransactionScope');
    expect(names).toContain('flowNodes');
    expect(names).toContain('allFlowNodes');
    expect(names).toContain('associations');
    expect(names).toContain('extensions');
    expect(names).toContain('definitionsId');
    expect(names).toContain('messages');
    expect(names).toContain('signals');
    expect(names).toContain('linterScores');
  });

  it('recurses into flowNodes up to the given depth but keeps allFlowNodes flat', () => {
    const selection = buildProcessModelSelection(2);
    const fields = selection.fields ?? [];

    const flowNodesField = fields.find(
      (field): field is { name: string; on?: Record<string, SelectionField[]> } =>
        typeof field !== 'string' && field.name === 'flowNodes',
    );
    const allFlowNodesField = fields.find(
      (field): field is { name: string; on?: Record<string, SelectionField[]> } =>
        typeof field !== 'string' && field.name === 'allFlowNodes',
    );

    const flowNodesSubProcessFields = flowNodesField?.on?.['SubProcessNode'] ?? [];
    expect(fieldNames(flowNodesSubProcessFields)).toContain('flowNodes');

    const allFlowNodesSubProcessFields = allFlowNodesField?.on?.['SubProcessNode'] ?? [];
    expect(fieldNames(allFlowNodesSubProcessFields)).not.toContain('flowNodes');
  });
});
