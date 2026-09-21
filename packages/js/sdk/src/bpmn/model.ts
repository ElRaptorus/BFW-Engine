import type { FlowNodeType } from '../types/enums.js';

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

export interface BpmnProcess {
  id: string;
  name: string | null;
  version: string | null;
  isExecutable: boolean;
  /** True when this process is the inner scope of a `<bpmn:transaction>`. */
  isTransactionScope: boolean;
  /** True when this process is the inner scope of a `<bpmn:adHocSubProcess>`. */
  isAdHocScope: boolean;
  correlationKey: string | null;
  flowNodes: FlowNode[];
  sequenceFlows: SequenceFlow[];
  lanes: Lane[];
  dataObjects: DataObject[];
  dataObjectReferences: DataObjectReference[];
  dataStores: DataStore[];
  dataStoreReferences: DataStoreReference[];
  /** `<bpmn:association>` elements, primarily compensation boundary → handler links. */
  associations: Association[];
  extensions: Extension[];
  linterScores: LinterRulesetScore[];
}

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
  standardLoop: StandardLoop | null;
  /**
   * `isForCompensation="true"` — the activity is a compensation handler. It has
   * no sequence flows and is reached only via a Compensation Boundary Event's
   * `<bpmn:association>`.
   */
  isForCompensation: boolean;
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

/**
 * A `<bpmn:association>` linking two elements. Used for compensation: a
 * directed association connects a Compensation Boundary Event (`sourceRef`) to
 * an `isForCompensation` handler activity (`targetRef`).
 */
export interface Association {
  id: string;
  sourceRef: string | null;
  targetRef: string | null;
  associationDirection: string | null;
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

/**
 * `<bpmn:loopCardinality>` is parsed (as `loopCardinality`) and rejected at
 * deploy time (`:loop_cardinality_not_supported`). Iteration count comes
 * exclusively from the input collection, capped by `bfw:maxIterations`.
 */
export interface MultiInstance {
  isSequential: boolean;
  collectionExpression: string | null;
  elementVariable: string | null;
  completionCondition: string | null;
  outputCollection: string | null;
  outputElementVariable: string | null;
  loopBreakCondition: string | null;
  loopInterval: string | null;
  maxIterations: number | null;
  loopCardinality: string | null;
}

export interface StandardLoop {
  testBefore: boolean;
  loopCondition: string | null;
  loopMaximum: number | null;
  loopInterval: string | null;
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


export interface StartEventTypeData {
  type: 'start_event';
  eventDefinition: EventDefinition;
  isInterrupting: boolean;
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
  /**
   * For a Compensation Boundary Event, the ID of the handler activity resolved
   * from the `<bpmn:association>` whose `sourceRef` is this event.
   */
  compensationHandlerId: string | null;
  outMappings: Mapping[];
  resultContract: Record<string, unknown> | null;
}

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
  /** `bfw:httpUrl` — target URL. Static text, not FEEL. */
  httpUrl: string | null;
  /** `bfw:httpMethod` — HTTP verb. Static text, not FEEL. */
  httpMethod: string | null;
  /** `bfw:httpBody` — FEEL expression for the request body. */
  httpBody: string | null;
  /** `bfw:httpAuthHeader` — FEEL expression for the Authorization header. */
  httpAuthHeader: string | null;
  /** `bfw:httpResponseHeaders` — FEEL expression mapping response headers into the output. */
  httpResponseHeaders: string | null;
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

/**
 * `implementation` selects the execution mode: `"feel"` evaluates the inline
 * `script`, `"dmn"` resolves `decisionRef` against a deployed DMN model.
 */
export interface BusinessRuleTaskTypeData extends WithMappings, WithContracts {
  type: 'business_rule_task';
  implementation: string | null;
  /** Inline FEEL expression from `<bpmn:script>`. Used when `implementation` is `"feel"`. */
  script: string | null;
  /** Legacy `bfw:ruleRef`. Retained for XML fidelity; plugin delegation was removed. */
  ruleRef: string | null;
  /** `bfw:decisionRef` — DMN model reference. Used when `implementation` is `"dmn"`. */
  decisionRef: string | null;
  /** `bfw:decisionElementId` — which `<decision>` to evaluate in a multi-decision model. */
  decisionElementId: string | null;
  /** `bfw:resultVariable` — output variable name for the decision result. */
  resultVariable: string | null;
  /** `bfw:traceUnmatchedRules` — include unmatched rule detail in the DMN trace. */
  traceUnmatchedRules: boolean;
}

export interface SendTaskTypeData extends WithMappings {
  type: 'send_task';
  messageRef: string | null;
  payloadContract: Record<string, unknown> | null;
}

export interface ReceiveTaskTypeData extends WithMappings {
  type: 'receive_task';
  messageRef: string | null;
  resultContract: Record<string, unknown> | null;
}

export interface CallActivityTypeData extends WithMappings {
  type: 'call_activity';
  calledElement: string | null;
  startEventId: string | null;
  /** Child `<bfw:version>` pin. `null` means latest enabled at enter time. The word `latest` is a literal version name, not a keyword. */
  calledProcessVersion: string | null;
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
  /** True when this subprocess is a `<bpmn:transaction>` element. */
  isTransaction: boolean;
  /** Value of the `method` attribute on `<bpmn:transaction>`. Parsed but not executed. */
  transactionMethod: string | null;
  /** True when this subprocess is a `<bpmn:adHocSubProcess>` element. */
  isAdHoc: boolean;
  /** Ad-hoc execution ordering. Defaults to `'parallel'`, matching BPMN's default. */
  adhocOrdering: 'parallel' | 'sequential';
  /** BPMN `cancelRemainingInstances` attribute. Defaults to `true`, matching BPMN's default. */
  cancelRemainingInstances: boolean;
  /** FEEL expression from `<completionCondition>`. Only set when `isAdHoc` is true. */
  adhocCompletionCondition: string | null;
  /** Plugin dispatch key for plugin-managed ad-hoc execution. Only set when `isAdHoc` is true. */
  implementation: string | null;
  /** FEEL expression from `bfw:activeElements`. Returns list of element IDs to auto-activate. */
  activeElementsExpression: string | null;
  flowNodes: FlowNode[];
  sequenceFlows: SequenceFlow[];
  dataObjects: DataObject[];
  dataObjectReferences: DataObjectReference[];
}

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

export interface NoneEventDefinition {
  type: 'none';
}

export interface MessageEventDefinition {
  type: 'message';
  messageRef: string | null;
  correlationRetrievalExpression: string | null;
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
