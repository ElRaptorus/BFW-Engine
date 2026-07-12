import type { EventDefinitionType, FlowNodeInstanceState, FlowNodeType, ProcessInstanceState } from '../types/enums.js';
import type { ErrorInfo } from '../types/error-info.js';

/**
 * Typed wrapper for engine events delivered over WebSocket.
 * The `type` field matches the event's discriminant for easy switching.
 */
export interface EngineEventEnvelope<T extends EngineEvent = EngineEvent> {
  type: T['type'];
  data: T;
  occurredAt: string;
}

/** Discriminated union of all engine event types. */
export type EngineEvent =
  | EngineStarted
  | EngineShutdown
  | EngineOverloaded
  | EngineRecovered
  | PluginQuarantined
  | ProcessInstanceStateChanged
  | ProcessInstanceRetried
  | FlowNodeInstanceStarted
  | FlowNodeInstanceFinished
  | FlowNodeInstanceStateChanged
  | UserTaskCreated
  | UserTaskFinished
  | UserTaskValidationFailed
  | PluginAsyncFlowNodeRehydrated
  | CallActivityChildStarted
  | SubProcessChildStarted
  | DataObjectWritten
  | ProcessDefinitionDeployed
  | ProcessDefinitionUndeployed
  | ProcessDefinitionEnabled
  | ProcessDefinitionDisabled
  | DecisionDefinitionDeployed
  | DecisionDefinitionUndeployed
  | DecisionEvaluated
  | TimerArmed
  | TimerFired
  | TimerCancelled
  | MessagePublished
  | MessageArrived
  | SignalPublished
  | SignalArrived
  | EscalationRaised
  | CompensationTriggered
  | ActivityCompensated
  | TransactionCancelled
  | EventSubprocessTriggered
  | SinkFailed;

export interface EngineStarted {
  type: 'EngineStarted';
  engineId: string;
  engineName: string;
  version: string;
  startedAt: string;
}

export interface EngineShutdown {
  type: 'EngineShutdown';
  engineId: string;
  reason: string;
  occurredAt: string;
}

export interface EngineOverloaded {
  type: 'EngineOverloaded';
  level: 'elevated' | 'critical';
  activeProcessInstances: number;
  limit: number;
  occurredAt: string;
}

export interface EngineRecovered {
  type: 'EngineRecovered';
  previousLevel: 'elevated' | 'critical';
  activeProcessInstances: number;
  limit: number;
  occurredAt: string;
}

export interface PluginQuarantined {
  type: 'PluginQuarantined';
  pluginName: string;
  tier: 'inbeam' | 'sidecar';
  reason: string;
  occurredAt: string;
}

export interface ProcessInstanceStateChanged {
  type: 'ProcessInstanceStateChanged';
  processInstanceId: string;
  processModelId: string;
  version: string;
  parentProcessInstanceId: string | null;
  rootProcessInstanceId: string | null;
  /**
   * UUID of the FNI (e.g. a Message/Signal throw event) that triggered this
   * process instance, or `null` for manually-started instances.
   */
  triggererFlowNodeInstanceId: string | null;
  oldState: ProcessInstanceState | null;
  newState: ProcessInstanceState;
  occurredAt: string;
}

/**
 * Emitted after a successful process instance retry. `processInstanceId` is
 * the root PI where the gen_statem was restarted. `targetProcessInstanceId`
 * is the PI the user targeted (equal to `processInstanceId` when retrying
 * the root directly).
 */
export interface ProcessInstanceRetried {
  type: 'ProcessInstanceRetried';
  processInstanceId: string;
  targetProcessInstanceId: string;
  processModelId: string;
  version: string;
  previousState: ProcessInstanceState;
  previousVersion: string | null;
  newVersion: string | null;
  resetToFlowNodeInstanceId: string | null;
  retriedBy: string;
  occurredAt: string;
}

export interface FlowNodeInstanceStarted {
  type: 'FlowNodeInstanceStarted';
  flowNodeInstanceId: string;
  processInstanceId: string;
  rootProcessInstanceId: string | null;
  flowNodeId: string;
  flowNodeType: FlowNodeType;
  eventType: EventDefinitionType | null;
  laneName: string | null;
  /**
   * Always `null` for `FlowNodeInstanceStarted`. The triggerer is only known
   * once the FNI receives an inbound event and is reported on
   * `FlowNodeInstanceFinished`. Present here for schema consistency.
   */
  triggererFlowNodeInstanceId: null;
  occurredAt: string;
}

export interface FlowNodeInstanceFinished {
  type: 'FlowNodeInstanceFinished';
  flowNodeInstanceId: string;
  processInstanceId: string;
  rootProcessInstanceId: string | null;
  flowNodeId: string;
  flowNodeType: FlowNodeType;
  eventType: EventDefinitionType | null;
  laneName: string | null;
  terminalState: FlowNodeInstanceState;
  /**
   * UUID of the FNI that triggered this one — set for catch events
   * (Message, Signal, Escalation boundary) that received a throw from another
   * FNI. `null` for all other flow node types and for non-`:finished` terminal
   * states.
   */
  triggererFlowNodeInstanceId: string | null;
  /**
   * Handler-specific metadata. For BusinessRuleTask FNIs in DMN mode this
   * contains the full evaluation trace (see `DmnFlowNodeTypeProperties`).
   * Keys inside this object are **snake_case** (opaque payload, not
   * camelCased by the Wire layer). Empty `{}` for non-success terminal
   * states or flow nodes without type-specific data.
   */
  typeProperties: Record<string, unknown>;
  /**
   * Structured error details for fatal FNIs. See {@link ErrorInfo}.
   * `null` for non-fatal terminal states.
   */
  errorInfo: ErrorInfo | null;
  occurredAt: string;
}

/**
 * Emitted when a flow node instance transitions between non-terminal states
 * (e.g. `active` to `waiting`). Enables the Debugger to track FNI state
 * without polling.
 */
export interface FlowNodeInstanceStateChanged {
  type: 'FlowNodeInstanceStateChanged';
  flowNodeInstanceId: string;
  processInstanceId: string;
  rootProcessInstanceId: string | null;
  flowNodeId: string;
  flowNodeType: FlowNodeType;
  eventType: EventDefinitionType | null;
  laneName: string | null;
  oldState: FlowNodeInstanceState;
  newState: FlowNodeInstanceState;
  occurredAt: string;
}

export interface UserTaskCreated {
  type: 'UserTaskCreated';
  flowNodeInstanceId: string;
  processInstanceId: string;
  rootProcessInstanceId: string | null;
  flowNodeId: string;
  assignees: string[];
  occurredAt: string;
}

export interface UserTaskFinished {
  type: 'UserTaskFinished';
  flowNodeInstanceId: string;
  processInstanceId: string;
  rootProcessInstanceId: string | null;
  flowNodeId: string;
  outcome: 'completed' | 'aborted';
  occurredAt: string;
}

export interface UserTaskValidationFailed {
  type: 'UserTaskValidationFailed';
  flowNodeInstanceId: string;
  processInstanceId: string;
  flowNodeId: string;
  violations: { message: string; path: string[] }[];
  occurredAt: string;
}

export interface PluginAsyncFlowNodeRehydrated {
  type: 'PluginAsyncFlowNodeRehydrated';
  flowNodeInstanceId: string;
  processInstanceId: string;
  pluginName: string | null;
  occurredAt: string;
}

export interface CallActivityChildStarted {
  type: 'CallActivityChildStarted';
  callActivityFlowNodeInstanceId: string;
  parentProcessInstanceId: string;
  childProcessInstanceId: string;
  childProcessModelId: string;
  childVersion: string;
  occurredAt: string;
}

/**
 * Emitted when an Embedded Subprocess or Event Subprocess handler spawns a
 * child process instance for its inner scope. Mirrors `CallActivityChildStarted`
 * but distinguishes subprocess children in observability.
 *
 * `isEventSubprocess` is `true` when the child was spawned by an Event
 * Subprocess (`<bpmn:subProcess triggeredByEvent="true">`) and `false` for a
 * plain embedded subprocess. This is the primary observability signal a
 * debugger uses to distinguish an ESP trigger from a normal subprocess entry.
 */
export interface SubProcessChildStarted {
  type: 'SubProcessChildStarted';
  subprocessFlowNodeInstanceId: string;
  parentProcessInstanceId: string;
  childProcessInstanceId: string;
  subprocessNodeId: string;
  childProcessModelId: string;
  childVersion: string;
  isEventSubprocess: boolean;
  occurredAt: string;
}

/**
 * Emitted after each successful Data Object write via a Data Output Association.
 * Published from `DataObjectWriter` after the DB transaction commits.
 */
export interface DataObjectWritten {
  type: 'DataObjectWritten';
  processInstanceId: string;
  rootProcessInstanceId: string | null;
  flowNodeInstanceId: string;
  dataObjectId: string;
  writeId: string;
  previousValue: unknown | null;
  value: unknown;
  createdAt: string;
}

/**
 * Emitted when an EventSink handler throws during event processing.
 * This event does NOT reach the WebSocket sink — only in-process
 * plugin EventSinks see it.
 */
export interface SinkFailed {
  type: 'SinkFailed';
  sinkName: string;
  eventKind: string;
  reason: string;
  occurredAt: string;
}

/**
 * Emitted when a BPMN process definition version is deployed to the engine.
 *
 * The `source` field indicates who initiated the deployment:
 * - `"user:<identity_id>"` for REST-initiated deploys
 * - `"plugin:<plugin_name>"` for plugin-initiated deploys
 */
export interface ProcessDefinitionDeployed {
  type: 'ProcessDefinitionDeployed';
  processModelId: string;
  version: string;
  source: string;
  occurredAt: string;
}

/**
 * Emitted when a BPMN process definition version is undeployed (soft-deleted).
 *
 * The `source` field indicates who initiated the undeploy:
 * - `"user:<identity_id>"` for REST-initiated deletes
 * - `"plugin:<plugin_name>"` for plugin-initiated deletes
 */
export interface ProcessDefinitionUndeployed {
  type: 'ProcessDefinitionUndeployed';
  processModelId: string;
  /** Version string of the deleted version, or null for bulk undeploy. */
  version: string | null;
  source: string;
  occurredAt: string;
}

/** Emitted when a BPMN process definition is re-enabled. */
export interface ProcessDefinitionEnabled {
  type: 'ProcessDefinitionEnabled';
  processModelId: string;
  source: string;
  occurredAt: string;
}

/** Emitted when a BPMN process definition is disabled. */
export interface ProcessDefinitionDisabled {
  type: 'ProcessDefinitionDisabled';
  processModelId: string;
  source: string;
  occurredAt: string;
}

/**
 * Emitted when a DMN decision definition is deployed to the engine.
 *
 * The `source` field indicates who initiated the deployment:
 * - `"user:<identity_id>"` for REST-initiated deploys
 * - `"plugin:<plugin_name>"` for plugin-initiated deploys
 */
export interface DecisionDefinitionDeployed {
  type: 'DecisionDefinitionDeployed';
  decisionDefinitionId: string;
  version: string;
  source: string;
  occurredAt: string;
}

/**
 * Emitted when a DMN decision definition is undeployed (soft-deleted).
 *
 * The `source` field indicates who initiated the undeploy:
 * - `"user:<identity_id>"` for REST-initiated deletes
 * - `"plugin:<plugin_name>"` for plugin-initiated deletes
 */
export interface DecisionDefinitionUndeployed {
  type: 'DecisionDefinitionUndeployed';
  decisionDefinitionId: string;
  /** Version string of the deleted version, or null for bulk undeploy. */
  version: string | null;
  source: string;
  occurredAt: string;
}

/**
 * Emitted after a successful ad-hoc DMN evaluation via REST or plugin facade.
 *
 * BRT evaluations within a process instance are observable through
 * `FlowNodeInstanceFinished` and its `typeProperties` — this event
 * covers only ad-hoc (non-BRT) evaluations.
 */
export interface DecisionEvaluated {
  type: 'DecisionEvaluated';
  decisionDefinitionId: string;
  decisionModelId: string | null;
  version: string | null;
  decisionVersionId: string | null;
  durationMicroseconds: number;
  source: string;
  occurredAt: string;
}

/**
 * Emitted when a timer is registered in the Scheduler.
 * The `kind` field distinguishes between catch (intermediate),
 * boundary, and start timers.
 */
export interface TimerArmed {
  type: 'TimerArmed';
  timerRef: string;
  processInstanceId: string | null;
  flowNodeInstanceId: string | null;
  flowNodeId: string;
  fireAt: string;
  kind: 'catch' | 'boundary' | 'start';
  occurredAt: string;
}

/** Emitted when a timer fires and is processed by the engine. */
export interface TimerFired {
  type: 'TimerFired';
  timerRef: string;
  processInstanceId: string | null;
  flowNodeInstanceId: string | null;
  flowNodeId: string;
  kind: 'catch' | 'boundary' | 'start';
  occurredAt: string;
}

/** Emitted when a timer is cancelled (host completed, PI terminated, etc.). */
export interface TimerCancelled {
  type: 'TimerCancelled';
  timerRef: string;
  processInstanceId: string | null;
  flowNodeInstanceId: string | null;
  reason: string;
  occurredAt: string;
}

/** Emitted after a message is published through the pipeline. */
export interface MessagePublished {
  type: 'MessagePublished';
  messageId: string;
  messageName: string;
  correlationValue: string | null;
  origin: {
    source: 'api' | 'pi' | 'plugin';
    processInstanceId?: string;
    flowNodeInstanceId?: string;
    pluginName?: string;
    triggeredBy?: string;
  };
  deliveries: { processInstanceId: string; flowNodeInstanceId: string }[];
  startedProcessInstanceIds: string[];
  pending: boolean;
  occurredAt: string;
}

/** Emitted when a message arrives at a waiting catch/boundary/receive subscription. */
export interface MessageArrived {
  type: 'MessageArrived';
  messageId: string;
  messageName: string;
  correlationValue: string | null;
  processInstanceId: string;
  flowNodeInstanceId: string;
  /** The message payload delivered to the subscriber. Opaque — keys are not camelCased. */
  payload: Record<string, unknown>;
  occurredAt: string;
}

/** Emitted after a signal is broadcast through the signal pipeline. */
export interface SignalPublished {
  type: 'SignalPublished';
  signalId: string;
  signalName: string;
  origin: {
    source: 'api' | 'pi' | 'plugin';
    processInstanceId?: string;
    flowNodeInstanceId?: string;
    pluginName?: string;
    triggeredBy?: string;
  };
  deliveries: { processInstanceId: string; flowNodeInstanceId: string }[];
  startedProcessInstanceIds: string[];
  pending: boolean;
  occurredAt: string;
}

/** Emitted when a signal arrives at a waiting catch/boundary subscription. */
export interface SignalArrived {
  type: 'SignalArrived';
  signalId: string;
  signalName: string;
  processInstanceId: string;
  flowNodeInstanceId: string;
  occurredAt: string;
}

/**
 * Emitted when an Escalation is raised by an Escalation End Event or an
 * Escalation Intermediate Throw Event. Always emitted on throw, regardless
 * of whether the escalation is eventually caught in an ancestor scope.
 */
export interface EscalationRaised {
  type: 'EscalationRaised';
  escalationCode: string | null;
  escalationName: string | null;
  processInstanceId: string;
  rootProcessInstanceId: string | null;
  flowNodeInstanceId: string;
  flowNodeId: string;
  /** Whether this is a terminal throw (end event) or a pass-through throw (intermediate). */
  throwType: 'end_event' | 'intermediate_throw';
  occurredAt: string;
}

/**
 * Emitted by the scope PI when an Event Subprocess trigger fires and spawns
 * an ESP child PI. The Studio debugger primarily consumes
 * `SubProcessChildStarted` (with `isEventSubprocess`); this event
 * additionally exposes the trigger kind and interrupting flag.
 */
export interface EventSubprocessTriggered {
  type: 'EventSubprocessTriggered';
  scopeProcessInstanceId: string;
  rootProcessInstanceId: string;
  subprocessNodeId: string;
  childProcessInstanceId: string;
  triggerKind: 'message' | 'signal' | 'timer' | 'error' | 'escalation' | 'conditional' | 'compensation';
  isInterrupting: boolean;
  occurredAt: string;
}

/**
 * Emitted when a Compensate Throw or Compensate End Event fires, before
 * any compensation handler activities are dispatched.
 *
 * `throwType` distinguishes `"throw"` (intermediate — flow continues after
 * handlers) from `"end"` (token consumed, PI may reach `compensated`).
 * `targetCount` is the number of handler activities that will be dispatched
 * (may be 0 if no completed activities have compensation handlers).
 */
export interface CompensationTriggered {
  type: 'CompensationTriggered';
  processInstanceId: string;
  rootProcessInstanceId: string | null;
  flowNodeInstanceId: string;
  flowNodeId: string;
  throwType: 'throw' | 'end';
  activityRef: string | null;
  targetCount: number;
  occurredAt: string;
}

/**
 * Emitted when a Transaction subprocess child PI transitions to `cancelled`.
 *
 * Fires after any automatic compensation run triggered by the Cancel End
 * Event has completed (or immediately if no compensable activities existed).
 *
 * `transactionNodeId` is the BPMN element ID of the `<bpmn:transaction>`
 * subprocess shell in the parent process. `compensationHandlerCount` is
 * the number of completed activities that had registered compensation
 * handlers.
 */
export interface TransactionCancelled {
  type: 'TransactionCancelled';
  processInstanceId: string;
  rootProcessInstanceId: string | null;
  transactionNodeId: string | null;
  compensationHandlerCount: number;
  occurredAt: string;
}

/**
 * Emitted after each compensation handler activity finishes successfully.
 *
 * `compensatedFniId` identifies the original completed FNI whose work was
 * undone; `handlerFniId` identifies the compensation handler FNI that
 * executed; `throwFniId` identifies the Compensate Throw/End FNI that
 * initiated the compensation run.
 */
export interface ActivityCompensated {
  type: 'ActivityCompensated';
  processInstanceId: string;
  rootProcessInstanceId: string | null;
  compensatedFniId: string;
  handlerFniId: string;
  throwFniId: string;
  flowNodeId: string;
  handlerActivityId: string;
  occurredAt: string;
}
