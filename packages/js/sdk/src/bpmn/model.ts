/**
 * BPMN model types mirroring the engine's internal `EvilEngine.BPMN.Model.*`
 * structs. The SDK parser produces these types, and the engine's golden JSON
 * snapshots validate structural parity.
 */
import type { FlowNodeType } from '../types/enums.js';

// ---------------------------------------------------------------------------
// Root container
// ---------------------------------------------------------------------------

/** Root container for a parsed BPMN XML document. */
export interface BpmnDefinitions {
  definitionsId: string | null;
  processes: BpmnProcess[];
  messages: MessageDefinition[];
  signals: SignalDefinition[];
  errors: ErrorDefinition[];
  escalations: EscalationDefinition[];
  /** The original BPMN XML string that was parsed. */
  rawXml: string;
}

// ---------------------------------------------------------------------------
// Global definitions (declared at <bpmn:definitions> level)
// ---------------------------------------------------------------------------

export interface MessageDefinition {
  id: string;
  name: string | null;
}

export interface SignalDefinition {
  id: string;
  name: string | null;
}

export interface ErrorDefinition {
  id: string;
  name: string | null;
  errorCode: string | null;
}

export interface EscalationDefinition {
  id: string;
  name: string | null;
  escalationCode: string | null;
}

// ---------------------------------------------------------------------------
// Process
// ---------------------------------------------------------------------------

export interface BpmnProcess {
  id: string;
  name: string | null;
  version: string | null;
  isExecutable: boolean;
  correlationKey: string | null;
  flowNodes: FlowNode[];
  sequenceFlows: SequenceFlow[];
  lanes: Lane[];
  dataObjects: DataObject[];
  dataObjectReferences: DataObjectReference[];
  dataStores: DataStore[];
  dataStoreReferences: DataStoreReference[];
  extensions: Extension[];
  linterScores: LinterRulesetScore[];
}

// ---------------------------------------------------------------------------
// FlowNode
// ---------------------------------------------------------------------------

export interface FlowNode {
  id: string;
  name: string | null;
  type: FlowNodeType;
  typeData: FlowNodeTypeData;
  incoming: string[];
  outgoing: string[];
  boundaryEventRefs: string[];
  dataContracts: DataContract[];
  dataInputAssociations: DataAssociation[];
  dataOutputAssociations: DataAssociation[];
  multiInstance: MultiInstance | null;
  documentation: string | null;
}

export interface SequenceFlow {
  id: string;
  name: string | null;
  sourceRef: string;
  targetRef: string;
  conditionExpression: string | null;
  isDefault: boolean;
}

// ---------------------------------------------------------------------------
// Supporting types
// ---------------------------------------------------------------------------

export interface Lane {
  id: string;
  name: string | null;
  flowNodeRefs: string[];
}

export interface DataObject {
  id: string;
  name: string | null;
  itemSubjectRef: string | null;
  valueContract: Record<string, unknown> | null;
}

export interface DataObjectReference {
  id: string;
  name: string | null;
  dataObjectRef: string | null;
  dataState: string | null;
}

export interface DataStore {
  id: string;
  name: string | null;
  capacity: number | null;
  isUnlimited: boolean;
  itemSubjectRef: string | null;
}

export interface DataStoreReference {
  id: string;
  name: string | null;
  dataStoreRef: string | null;
  dataState: string | null;
}

export interface DataAssociation {
  id: string;
  sourceRef: string | null;
  targetRef: string | null;
  valueExpression: string | null;
}

export interface Extension {
  key: string;
  value: string | null;
  attributes: Record<string, string>;
  children: Extension[];
}

export interface LinterRulesetScore {
  rulesetId: string;
  score: number;
  checks: Record<string, unknown>;
}

export interface MultiInstance {
  isSequential: boolean;
  cardinalityExpression: string | null;
  collectionExpression: string | null;
  elementVariable: string | null;
  completionCondition: string | null;
  outputCollection: string | null;
  loopBreakCondition: string | null;
  loopInterval: string | null;
  maxIterations: number | null;
}

export interface DataContract {
  direction: 'input' | 'output';
  jsonSchema: Record<string, unknown>;
  compiledSchema: null;
}

/**
 * A single input or output variable mapping.
 * `source` is a FEEL expression evaluated against the current context.
 * `target` is the variable name in the destination scope.
 */
export interface Mapping {
  source: string;
  target: string;
}

/** Shared shape for elements that support FEEL-based input/output mappings. */
export interface WithMappings {
  inMappings: Mapping[];
  outMappings: Mapping[];
}

/** Shared shape for elements that support JSON Schema payload/result contracts. */
export interface WithContracts {
  payloadContract: Record<string, unknown> | null;
  resultContract: Record<string, unknown> | null;
}

// ---------------------------------------------------------------------------
// FlowNodeTypeData — Events
// ---------------------------------------------------------------------------

export interface StartEventTypeData {
  type: 'start_event';
  eventDefinition: EventDefinition;
  resultContract: Record<string, unknown> | null;
}

export interface EndEventTypeData {
  type: 'end_event';
  eventDefinition: EventDefinition;
  inMappings: Mapping[];
  payloadContract: Record<string, unknown> | null;
}

export interface IntermediateCatchEventTypeData {
  type: 'intermediate_catch_event';
  eventDefinition: EventDefinition;
  outMappings: Mapping[];
  resultContract: Record<string, unknown> | null;
}

export interface IntermediateThrowEventTypeData {
  type: 'intermediate_throw_event';
  eventDefinition: EventDefinition;
  inMappings: Mapping[];
  payloadContract: Record<string, unknown> | null;
}

export interface BoundaryEventTypeData {
  type: 'boundary_event';
  eventDefinition: EventDefinition;
  attachedToRef: string | null;
  cancelActivity: boolean;
  outMappings: Mapping[];
  resultContract: Record<string, unknown> | null;
}

// ---------------------------------------------------------------------------
// FlowNodeTypeData — Activities
// ---------------------------------------------------------------------------

export interface TaskTypeData {
  type: 'task';
}

export interface UserTaskTypeData extends WithMappings, WithContracts {
  type: 'user_task';
  formSchema: Record<string, unknown> | null;
  formActions: Record<string, unknown>[] | null;
  assigneesExpression: string | null;
  dueDate: string | null;
  priority: number | null;
}

export interface ServiceTaskTypeData extends WithMappings, WithContracts {
  type: 'service_task';
  implementation: string | null;
  /** Handler-specific extension elements as a flat key/value bag. */
  serviceTaskTypeConfig: Record<string, unknown>;
}

export interface ManualTaskTypeData {
  type: 'manual_task';
  requireConfirmation: boolean;
}

export interface ScriptTaskTypeData extends WithMappings, WithContracts {
  type: 'script_task';
  scriptFormat: string | null;
  script: string | null;
  scriptRef: string | null;
}

export interface BusinessRuleTaskTypeData {
  type: 'business_rule_task';
  implementation: string | null;
  ruleRef: string | null;
}

export interface SendTaskTypeData {
  type: 'send_task';
  messageRef: string | null;
  payloadContract: Record<string, unknown> | null;
  inMappings: Mapping[];
}

export interface ReceiveTaskTypeData {
  type: 'receive_task';
  messageRef: string | null;
  resultContract: Record<string, unknown> | null;
  outMappings: Mapping[];
}

export interface CallActivityTypeData extends WithMappings {
  type: 'call_activity';
  calledElement: string | null;
  startEventId: string | null;
}

/**
 * `triggeredByEvent` distinguishes event sub-processes (`true`) from
 * normal embedded sub-processes (`false`).
 *
 * Inner `flowNodes` and `sequenceFlows` form the subprocess's embedded
 * scope graph. `dataObjects` / `dataObjectReferences` are scoped to this
 * subprocess. Mappings and contracts follow the same pattern as
 * Call Activities.
 */
export interface SubProcessTypeData extends WithMappings, WithContracts {
  type: 'sub_process';
  triggeredByEvent: boolean;
  flowNodes: FlowNode[];
  sequenceFlows: SequenceFlow[];
  dataObjects: DataObject[];
  dataObjectReferences: DataObjectReference[];
}

// ---------------------------------------------------------------------------
// FlowNodeTypeData — Gateways
// ---------------------------------------------------------------------------

export interface ExclusiveGatewayTypeData {
  type: 'exclusive_gateway';
  defaultFlowRef: string | null;
}

export interface ParallelGatewayTypeData {
  type: 'parallel_gateway';
}

export interface InclusiveGatewayTypeData {
  type: 'inclusive_gateway';
  defaultFlowRef: string | null;
}

export interface EventBasedGatewayTypeData {
  type: 'event_based_gateway';
}

export interface ComplexGatewayTypeData {
  type: 'complex_gateway';
  activationCondition: string | null;
}

// ---------------------------------------------------------------------------
// Discriminated union
// ---------------------------------------------------------------------------

export type FlowNodeTypeData =
  | StartEventTypeData
  | EndEventTypeData
  | IntermediateCatchEventTypeData
  | IntermediateThrowEventTypeData
  | BoundaryEventTypeData
  | TaskTypeData
  | UserTaskTypeData
  | ServiceTaskTypeData
  | ManualTaskTypeData
  | ScriptTaskTypeData
  | BusinessRuleTaskTypeData
  | SendTaskTypeData
  | ReceiveTaskTypeData
  | CallActivityTypeData
  | SubProcessTypeData
  | ExclusiveGatewayTypeData
  | ParallelGatewayTypeData
  | InclusiveGatewayTypeData
  | EventBasedGatewayTypeData
  | ComplexGatewayTypeData;

// ---------------------------------------------------------------------------
// Event definition types
// ---------------------------------------------------------------------------

export interface NoneEventDefinition {
  type: 'none';
}

export interface MessageEventDefinition {
  type: 'message';
  messageRef: string | null;
  correlationRetrievalExpression: string | null;
  payloadExpression: string | null;
  eventMapping: string | null;
}

export interface SignalEventDefinition {
  type: 'signal';
  signalRef: string | null;
}

export interface TimerEventDefinition {
  type: 'timer';
  timeDate: string | null;
  timeDuration: string | null;
  timeCycle: string | null;
}

export interface ErrorEventDefinition {
  type: 'error';
  errorRef: string | null;
  errorCode: string | null;
  errorMessage: string | null;
}

export interface EscalationEventDefinition {
  type: 'escalation';
  escalationRef: string | null;
  escalationCode: string | null;
}

export interface ConditionalEventDefinition {
  type: 'conditional';
  conditionExpression: string | null;
}

export interface CompensationEventDefinition {
  type: 'compensation';
  activityRef: string | null;
  waitForCompletion: boolean;
}

export interface TerminateEventDefinition {
  type: 'terminate';
}

export interface CancelEventDefinition {
  type: 'cancel';
}

export interface LinkEventDefinition {
  type: 'link';
  linkName: string | null;
}

export type EventDefinition =
  | NoneEventDefinition
  | MessageEventDefinition
  | SignalEventDefinition
  | TimerEventDefinition
  | ErrorEventDefinition
  | EscalationEventDefinition
  | ConditionalEventDefinition
  | CompensationEventDefinition
  | TerminateEventDefinition
  | CancelEventDefinition
  | LinkEventDefinition;
