/**
 * Typed selection-set helpers for the BPMN **Model graph** (Phase 6.1, WP-6).
 *
 * The Model graph (`ProcessVersion.processModel`, `FlowNodeInstance.flowNode`,
 * `FlowNodeInstance.processVersion`) is polymorphic: `flowNode` is a GraphQL
 * interface with 21 concrete `*Node` types, and `eventDefinition` is a union
 * with 11 concrete types. The flat `F extends string` field-union pattern
 * used elsewhere in this package (see `fields.ts`) cannot express "select
 * these common fields, plus these extra fields only when the concrete type
 * is X" — GraphQL needs inline fragments (`... on ServiceTaskNode { ... }`)
 * for that.
 *
 * `SelectionField` is a small recursive selection-set primitive that adds
 * nested-object and inline-fragment support on top of the existing flat
 * field arrays, without breaking any existing `string[]` callers (a plain
 * field name is still a valid `SelectionField`).
 */

/**
 * One entry in a GraphQL selection set: either a bare scalar/leaf field name
 * (camelCase; the query builder converts to the wire's snake_case), or a
 * nested selection for an object/interface/union field.
 */
export type SelectionField = string | NestedSelectionField;

/** A nested selection: an object field with its own sub-selection, optionally with inline fragments for interface/union members. */
export interface NestedSelectionField {
  /** The field name to select (camelCase). */
  name: string;
  /** Fields to select on every concrete type (interface/object common fields). */
  fields?: SelectionField[];
  /**
   * Inline fragments keyed by GraphQL type name (e.g. `"ServiceTaskNode"`,
   * `"MessageEventDefinition"`) for interface/union fields. Each value is
   * the selection set for that concrete type.
   */
  on?: Record<string, SelectionField[]>;
}

/**
 * Common fields shared by every concrete `*Node` type, mirrored from
 * `EvilEngineWeb.Graphql.ModelSchema.CommonFields.common_flow_node_fields/0`.
 */
export const FLOW_NODE_COMMON_FIELDS: SelectionField[] = [
  'id',
  'name',
  'type',
  'incoming',
  'outgoing',
  'boundaryEventRefs',
  'isForCompensation',
  'documentation',
  'parentSubProcessId',
  { name: 'dataContracts', fields: ['direction', 'jsonSchema'] },
  { name: 'dataInputAssociations', fields: ['id', 'sourceRef', 'targetRef', 'valueExpression'] },
  { name: 'dataOutputAssociations', fields: ['id', 'sourceRef', 'targetRef', 'valueExpression'] },
  {
    name: 'multiInstance',
    fields: [
      'isSequential',
      'collectionExpression',
      'elementVariable',
      'completionCondition',
      'outputCollection',
      'outputElementVariable',
      'loopBreakCondition',
      'loopInterval',
      'maxIterations',
    ],
  },
  { name: 'standardLoop', fields: ['testBefore', 'loopCondition', 'loopMaximum', 'loopInterval'] },
];

/** `Mapping.{source,target}` — used by every `*Node` type exposing `inMappings`/`outMappings`. */
export const MAPPING_FIELDS: SelectionField[] = ['source', 'target'];

/**
 * Inline fragments covering every concrete member of the `EventDefinition`
 * union (11 types), for use as the `on` map of an `eventDefinition` field.
 */
export const EVENT_DEFINITION_FRAGMENTS: Record<string, SelectionField[]> = {
  NoneEventDefinition: ['isNone'],
  MessageEventDefinition: ['messageRef', 'correlationRetrievalExpression'],
  SignalEventDefinition: ['signalRef'],
  TimerEventDefinition: ['timeDate', 'timeDuration', 'timeCycle'],
  ErrorEventDefinition: ['errorRef', 'errorCode', 'errorMessage'],
  EscalationEventDefinition: ['escalationRef', 'escalationCode'],
  ConditionalEventDefinition: ['conditionExpression'],
  CompensationEventDefinition: ['activityRef', 'waitForCompletion'],
  TerminateEventDefinition: ['isTerminate'],
  CancelEventDefinition: ['isCancel'],
  LinkEventDefinition: ['linkName'],
};

function mappingFieldsAsNested(fieldName: string): SelectionField[] {
  return [{ name: fieldName, fields: MAPPING_FIELDS }];
}

const SEQUENCE_FLOW_FIELDS: SelectionField[] = [
  'id',
  'name',
  'sourceRef',
  'targetRef',
  'conditionExpression',
  'isDefault',
];

/**
 * Per-type extra fields (beyond `FLOW_NODE_COMMON_FIELDS`) for the 21 concrete
 * `*Node` types. Empty arrays mean the type has **no** extra fields — common
 * interface fields already cover it. Those entries must **not** be serialized
 * as `... on TaskNode { }`: GraphQL forbids empty selection sets, and Absinthe
 * reports `syntax error before: '}'`. `buildFlowNodeSelection` omits empty
 * `on` entries; the client query builder also skips empty fragments.
 */
export const FLOW_NODE_TYPE_FIELDS: Record<string, SelectionField[]> = {
  TaskNode: [],
  UserTaskNode: [
    ...mappingFieldsAsNested('inMappings'),
    ...mappingFieldsAsNested('outMappings'),
    'formSchema',
    'formActions',
    'assigneesExpression',
    'payloadContract',
    'resultContract',
    'dueDate',
    'priority',
  ],
  ServiceTaskNode: [
    ...mappingFieldsAsNested('inMappings'),
    ...mappingFieldsAsNested('outMappings'),
    'implementation',
    'payloadContract',
    'resultContract',
    'httpUrl',
    'httpMethod',
    'httpBody',
    'httpAuthHeader',
    'httpResponseHeaders',
  ],
  ManualTaskNode: ['requireConfirmation'],
  ScriptTaskNode: [
    ...mappingFieldsAsNested('inMappings'),
    ...mappingFieldsAsNested('outMappings'),
    'scriptFormat',
    'script',
    'scriptRef',
    'payloadContract',
    'resultContract',
  ],
  BusinessRuleTaskNode: [
    ...mappingFieldsAsNested('inMappings'),
    ...mappingFieldsAsNested('outMappings'),
    'implementation',
    'script',
    'ruleRef',
    'decisionRef',
    'decisionElementId',
    'resultVariable',
    'traceUnmatchedRules',
    'payloadContract',
    'resultContract',
  ],
  SendTaskNode: [
    ...mappingFieldsAsNested('inMappings'),
    ...mappingFieldsAsNested('outMappings'),
    'messageRef',
    'payloadContract',
  ],
  ReceiveTaskNode: [
    { name: 'inMappings', fields: MAPPING_FIELDS },
    { name: 'outMappings', fields: MAPPING_FIELDS },
    'messageRef',
    'resultContract',
  ],
  CallActivityNode: [
    ...mappingFieldsAsNested('inMappings'),
    ...mappingFieldsAsNested('outMappings'),
    'calledElement',
    'startEventId',
    'calledProcessVersion',
  ],
  SubProcessNode: [
    ...mappingFieldsAsNested('inMappings'),
    ...mappingFieldsAsNested('outMappings'),
    'triggeredByEvent',
    'isTransaction',
    'transactionMethod',
    'isAdHoc',
    'adhocOrdering',
    'cancelRemainingInstances',
    'adhocCompletionCondition',
    'implementation',
    'activeElementsExpression',
    'payloadContract',
    'resultContract',
    { name: 'dataObjects', fields: ['id', 'name', 'itemSubjectRef', 'valueContract'] },
    {
      name: 'dataObjectReferences',
      fields: ['id', 'name', 'dataObjectRef', 'dataState'],
    },
    { name: 'sequenceFlows', fields: SEQUENCE_FLOW_FIELDS },
    // `flowNodes` (recursive) is intentionally omitted here — see
    // `buildFlowNodeSelection(depth)` below, which adds it up to `depth`.
  ],
  ExclusiveGatewayNode: ['defaultFlowRef'],
  ParallelGatewayNode: [],
  InclusiveGatewayNode: ['defaultFlowRef'],
  EventBasedGatewayNode: [],
  ComplexGatewayNode: ['activationCondition'],
  UnknownNode: ['elementName', 'attributes'],
  StartEventNode: [{ name: 'eventDefinition', on: EVENT_DEFINITION_FRAGMENTS }, 'resultContract', 'isInterrupting'],
  EndEventNode: [
    { name: 'eventDefinition', on: EVENT_DEFINITION_FRAGMENTS },
    { name: 'inMappings', fields: MAPPING_FIELDS },
    'payloadContract',
  ],
  IntermediateCatchEventNode: [
    { name: 'eventDefinition', on: EVENT_DEFINITION_FRAGMENTS },
    { name: 'outMappings', fields: MAPPING_FIELDS },
    'resultContract',
  ],
  IntermediateThrowEventNode: [
    { name: 'eventDefinition', on: EVENT_DEFINITION_FRAGMENTS },
    { name: 'inMappings', fields: MAPPING_FIELDS },
    'payloadContract',
  ],
  BoundaryEventNode: [
    { name: 'eventDefinition', on: EVENT_DEFINITION_FRAGMENTS },
    'attachedToRef',
    'cancelActivity',
    'compensationHandlerId',
    { name: 'outMappings', fields: MAPPING_FIELDS },
    'resultContract',
  ],
};

/**
 * Builds a full `flowNode` selection: common interface fields plus an
 * inline fragment per concrete `*Node` type. When `depth > 0`, `SubProcessNode`
 * additionally selects `flowNodes` recursively (one level per remaining
 * depth) so nested subprocess scopes can be rendered without a second
 * round-trip.
 *
 * @param depth - How many nested `SubProcessNode.flowNodes` levels to
 *   include. `0` (default) omits nested flow nodes entirely.
 */
export function buildFlowNodeSelection(depth = 0): NestedSelectionField {
  const on: Record<string, SelectionField[]> = {};
  for (const [typeName, fields] of Object.entries(FLOW_NODE_TYPE_FIELDS)) {
    if (fields.length > 0) {
      on[typeName] = [...fields];
    }
  }

  if (depth > 0) {
    const nested = buildFlowNodeSelection(depth - 1);
    on['SubProcessNode'] = [
      ...(FLOW_NODE_TYPE_FIELDS['SubProcessNode'] ?? []),
      { name: 'flowNodes', fields: nested.fields ?? [], on: nested.on ?? {} },
    ];
  }

  return { name: 'flowNode', fields: [...FLOW_NODE_COMMON_FIELDS], on };
}

/**
 * Builds a `processModel` selection: `ProcessModel` scalar fields plus the
 * `flowNodes` tree (recursing `depth` levels into nested subprocess scopes)
 * and the flat `allFlowNodes` index (never recursive — it is already flat).
 *
 * @param depth - How many nested `SubProcessNode.flowNodes` levels to
 *   include under `flowNodes`. Defaults to `4`, deep enough for realistic
 *   diagrams (subprocess-in-subprocess-in-ad-hoc, etc.) without risking
 *   unbounded query size for pathological inputs.
 */
export function buildProcessModelSelection(depth = 4): NestedSelectionField {
  const flowNodeSelection = buildFlowNodeSelection(depth);
  const allFlowNodesSelection = buildFlowNodeSelection(0);

  return {
    name: 'processModel',
    fields: [
      'id',
      'name',
      'version',
      'isExecutable',
      'isTransactionScope',
      'isAdHocScope',
      'correlationKey',
      { name: 'flowNodes', fields: flowNodeSelection.fields ?? [], on: flowNodeSelection.on ?? {} },
      { name: 'allFlowNodes', fields: allFlowNodesSelection.fields ?? [], on: allFlowNodesSelection.on ?? {} },
      { name: 'sequenceFlows', fields: SEQUENCE_FLOW_FIELDS },
      { name: 'lanes', fields: ['id', 'name', 'flowNodeRefs'] },
      { name: 'dataObjects', fields: ['id', 'name', 'itemSubjectRef', 'valueContract'] },
      { name: 'dataObjectReferences', fields: ['id', 'name', 'dataObjectRef', 'dataState'] },
      { name: 'associations', fields: ['id', 'sourceRef', 'targetRef', 'associationDirection'] },
      {
        name: 'extensions',
        fields: ['key', 'value', 'attributes', { name: 'children', fields: ['key', 'value', 'attributes'] }],
      },
      'definitionsId',
      { name: 'messages', fields: ['id', 'name'] },
      { name: 'signals', fields: ['id', 'name'] },
      { name: 'errors', fields: ['id', 'name', 'errorCode'] },
      { name: 'escalations', fields: ['id', 'name', 'escalationCode'] },
      {
        name: 'linterScores',
        fields: [
          'rulesetId',
          'scorePercent',
          'complianceStatus',
          'computedAtIso',
          'schemaVersion',
          'maxPoints',
          'penaltyPoints',
          'rawErrorFindings',
          'rawWarningFindings',
        ],
      },
    ],
  };
}
