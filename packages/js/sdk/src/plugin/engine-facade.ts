import type { DmnServiceEvaluationResult } from '../dmn/model.js';
import type { EngineEvent } from '../events/engine-events.js';
import type {
  DataObjectValueField,
  DecisionDefinitionField,
  DecisionVersionField,
  FlowNodeInstanceField,
  ProcessInstanceField,
  ProcessModelField,
  ProcessVersionField,
} from '../graphql/fields.js';
import type {
  DataObjectValueFilter,
  DecisionDefinitionFilter,
  DecisionVersionFilter,
  FlowNodeInstanceFilter,
  ProcessInstanceFilter,
  ProcessModelFilter,
  ProcessVersionFilter,
} from '../graphql/filters.js';
import type {
  DataObjectValueInclude,
  DecisionDefinitionInclude,
  FlowNodeInstanceInclude,
  ProcessInstanceInclude,
  ProcessModelInclude,
} from '../graphql/includes.js';
import type { PaginatedResult } from '../graphql/pagination.js';
import type { GetQueryOptions, ListQueryOptions } from '../graphql/query-options.js';
import type {
  AdHocActivateResult,
  AdHocActivity,
  AdHocCompleteResult,
  AdHocStatus,
} from '../types/adhoc-subprocess.js';
import type { DataObjectValue } from '../types/data-object-value.js';
import type { DecisionDefinition } from '../types/decision-definition.js';
import type { DecisionVersion } from '../types/decision-version.js';
import type { DeployResponse } from '../types/deploy.js';
import type { DmnDeployResponse } from '../types/dmn-deploy.js';
import type { EvaluationResult } from '../types/dmn-evaluate.js';
import type { FlowNodeInstance } from '../types/flow-node-instance.js';
import type { Identity } from '../types/identity.js';
import type { ProcessInstance } from '../types/process-instance.js';
import type { ProcessModel } from '../types/process-model.js';
import type { ProcessVersion } from '../types/process-version.js';
import type { StartResult } from '../types/start.js';
import type { TimerSchedule } from '../types/timer-schedule.js';
import type {
  EscalationTriggerResult,
  MessageTriggerResult,
  SignalTriggerResult,
  TimerTriggerResult,
} from '../types/trigger.js';
import type { FinishUserTaskRequest } from '../types/user-task.js';
import type { AuthProviderHandler } from './auth-provider.js';
import type { EventSinkHandler, EventSinkOptions } from './event-sink.js';
import type { NamedScriptHandler } from './named-script-handler.js';
import type { RestApiExtensionHandler } from './rest-api-extension.js';
import type { ServiceTaskHandler } from './service-task-handler.js';

/**
 * This interface mirrors the in-BEAM Elixir `BfwEngine.EngineFacade` struct
 * passed to plugin `on_load` / `on_ready`. Sidecar host (gRPC) is deferred
 * (PLUG-D1). PersistenceAdapter, MonitoringPanel, TimerSource, and
 * DataStoreAdapter plugin capabilities do not exist — do not register them.
 *
 * Registration methods accept the handler instance directly so that
 * TypeScript enforces the handler contract at compile time.
 *
 * Runtime operations are grouped into resource-scoped namespaces
 * (processes, processInstances, userTasks, manualTasks, serviceTasks, decisions, timers, etc.).
 */
export interface EngineFacade {
  engineId: string;
  engineName: string;
  version: string;

  registerServiceTaskHandler(implementation: string, handler: ServiceTaskHandler): Promise<RegistrationResult>;
  registerNamedScript(scriptKey: string, handler: NamedScriptHandler): Promise<RegistrationResult>;
  registerRestApiExtension(prefix: string, handler: RestApiExtensionHandler): Promise<RegistrationResult>;
  registerAuthProvider(handler: AuthProviderHandler): Promise<RegistrationResult>;
  registerEventSink(name: string, handler: EventSinkHandler, options?: EventSinkOptions): Promise<RegistrationResult>;

  publishEvent(event: EngineEvent): Promise<void>;
  getConfig(key: string): Promise<unknown>;

  processes: FacadeProcesses;
  processInstances: FacadeProcessInstances;
  userTasks: FacadeUserTasks;
  manualTasks: FacadeManualTasks;
  serviceTasks: FacadeServiceTasks;
  flowNodeInstances: FacadeFlowNodeInstances;
  dataObjects: FacadeDataObjects;
  messages: FacadeMessages;
  signals: FacadeSignals;
  escalations: FacadeEscalations;
  graphql: FacadeGraphql;
  adHocSubprocesses: FacadeAdHocSubprocesses;
  decisions: FacadeDecisions;
  timers: FacadeTimers;
}

/** Options for starting a process instance via the facade. */
export interface StartOptions {
  startEventId?: string;
  payload?: Record<string, unknown>;
  /** Immutable context variables accessible as `context.*` in FEEL expressions. Independent from the token payload. When omitted, `context` is empty. */
  context?: Record<string, unknown>;
  businessKey?: string;
}

export interface FacadeProcesses {
  list(): Promise<ProcessModel[]>;
  get(processModelId: string): Promise<ProcessModel>;
  getLatestVersion(processModelId: string): Promise<ProcessModel>;
  deploy(sources: string[]): Promise<DeployResponse>;
  enable(processModelId: string): Promise<void>;
  disable(processModelId: string): Promise<void>;
  deleteVersion(processModelId: string, version: string): Promise<void>;
  undeploy(processModelId: string): Promise<void>;
  start(processModelId: string, options?: StartOptions): Promise<StartResult>;
}

export interface FacadeProcessInstances {
  get(id: string): Promise<ProcessInstance>;
  abort(id: string, reason?: string): Promise<void>;
  retry(id: string, options?: { targetVersion?: string; resetToFlowNodeInstanceId?: string }): Promise<void>;
  delete(id: string): Promise<void>;
}

export interface FacadeUserTasks {
  finish(
    processInstanceId: string,
    flowNodeInstanceId: string,
    request: FinishUserTaskRequest,
    identity?: Identity,
  ): Promise<void>;
  cancel(processInstanceId: string, flowNodeInstanceId: string, reason?: string, identity?: Identity): Promise<void>;
}

/** Confirming Manual Tasks (`bfw:requireConfirmation`). `confirm` takes no payload: the entered token passes through. */
export interface FacadeManualTasks {
  confirm(processInstanceId: string, flowNodeInstanceId: string, identity?: Identity): Promise<void>;
  cancel(processInstanceId: string, flowNodeInstanceId: string, reason?: string, identity?: Identity): Promise<void>;
}

export interface FacadeServiceTasks {
  finishAsync(flowNodeInstanceId: string, output: Record<string, unknown>): Promise<void>;
  failAsync(flowNodeInstanceId: string, errorCode: string, errorMessage: string): Promise<void>;
}

export interface FacadeFlowNodeInstances {
  get(id: string): Promise<FlowNodeInstance>;
  listForProcessInstance(processInstanceId: string): Promise<FlowNodeInstance[]>;
}

export interface FacadeDataObjects {
  get(id: string): Promise<DataObjectValue>;
  listForInstance(processInstanceId: string): Promise<DataObjectValue[]>;
  historyForInstance(processInstanceId: string): Promise<DataObjectValue[]>;
}

export interface FacadeMessages {
  /** Publish a named message through the message correlation pipeline. */
  publish(
    messageName: string,
    correlationValue: string | null,
    payload: Record<string, unknown>,
  ): Promise<MessageTriggerResult>;
}

export interface FacadeSignals {
  /** Broadcast a named signal (no payload, no correlation). */
  publish(signalName: string): Promise<SignalTriggerResult>;
}

export interface FacadeEscalations {
  /** Inject an escalation code into waiting catchers (no payload). */
  publish(escalationCode: string): Promise<EscalationTriggerResult>;
}

export interface FacadeAdHocSubprocesses {
  getEnabledActivities(processInstanceId: string): Promise<AdHocActivity[]>;
  activateActivity(processInstanceId: string, activityId: string): Promise<AdHocActivateResult>;
  complete(processInstanceId: string): Promise<AdHocCompleteResult>;
  getStatus(processInstanceId: string): Promise<AdHocStatus>;
}

/**
 * Full typed GraphQL surface — mirrors GraphqlClient from @elraptorus/bfw_engine_client
 * exactly, so plugin developers get the same typed query builder as SDK client
 * consumers. All query-builder types (field literals, filters, sorts, pagination,
 * includes) are imported from @elraptorus/bfw_engine_sdk.
 */
export interface FacadeGraphql {
  queryProcessModels<SelectedField extends ProcessModelField>(
    options: ListQueryOptions<SelectedField, ProcessModelFilter, ProcessModelInclude>,
  ): Promise<PaginatedResult<Pick<ProcessModel, SelectedField>>>;

  getProcessModel<SelectedField extends ProcessModelField>(
    id: string,
    options: GetQueryOptions<SelectedField, ProcessModelInclude>,
  ): Promise<Pick<ProcessModel, SelectedField>>;

  queryProcessInstances<SelectedField extends ProcessInstanceField>(
    options: ListQueryOptions<SelectedField, ProcessInstanceFilter, ProcessInstanceInclude>,
  ): Promise<PaginatedResult<Pick<ProcessInstance, SelectedField>>>;

  getProcessInstance<SelectedField extends ProcessInstanceField>(
    id: string,
    options: GetQueryOptions<SelectedField, ProcessInstanceInclude>,
  ): Promise<Pick<ProcessInstance, SelectedField>>;

  queryFlowNodeInstances<SelectedField extends FlowNodeInstanceField>(
    options: ListQueryOptions<SelectedField, FlowNodeInstanceFilter, FlowNodeInstanceInclude>,
  ): Promise<PaginatedResult<Pick<FlowNodeInstance, SelectedField>>>;

  getFlowNodeInstance<SelectedField extends FlowNodeInstanceField>(
    id: string,
    options: GetQueryOptions<SelectedField, FlowNodeInstanceInclude>,
  ): Promise<Pick<FlowNodeInstance, SelectedField>>;

  queryDataObjectValues<SelectedField extends DataObjectValueField>(
    options: ListQueryOptions<SelectedField, DataObjectValueFilter, DataObjectValueInclude>,
  ): Promise<PaginatedResult<Pick<DataObjectValue, SelectedField>>>;

  getDataObjectValue<SelectedField extends DataObjectValueField>(
    id: string,
    options: GetQueryOptions<SelectedField, DataObjectValueInclude>,
  ): Promise<Pick<DataObjectValue, SelectedField>>;

  queryDataObjectHistory<SelectedField extends DataObjectValueField>(
    options: ListQueryOptions<SelectedField, DataObjectValueFilter, DataObjectValueInclude>,
  ): Promise<PaginatedResult<Pick<DataObjectValue, SelectedField>>>;

  queryProcessVersions<SelectedField extends ProcessVersionField>(
    options: ListQueryOptions<SelectedField, ProcessVersionFilter, Record<string, never>>,
  ): Promise<PaginatedResult<Pick<ProcessVersion, SelectedField>>>;

  queryDecisionVersions<SelectedField extends DecisionVersionField>(
    options: ListQueryOptions<SelectedField, DecisionVersionFilter, Record<string, never>>,
  ): Promise<PaginatedResult<Pick<DecisionVersion, SelectedField>>>;

  queryDecisionDefinitions<SelectedField extends DecisionDefinitionField>(
    options: ListQueryOptions<SelectedField, DecisionDefinitionFilter, DecisionDefinitionInclude>,
  ): Promise<PaginatedResult<Pick<DecisionDefinition, SelectedField>>>;

  getDecisionDefinition<SelectedField extends DecisionDefinitionField>(
    decisionDefinitionId: string,
    options: { fields: SelectedField[] },
  ): Promise<Pick<DecisionDefinition, SelectedField> | null>;

  raw<Result = unknown>(query: string, variables?: Record<string, unknown>): Promise<Result>;
}

export type RegistrationResult = { status: 'ok' } | { status: 'conflict'; incumbentPluginName: string };

/** Optional keyword filters for listing timer cycle schedules. */
export interface FacadeTimerScheduleFilters {
  processVersionId?: string;
  enabled?: boolean;
}

/** Optional evaluate options matching `BfwEngine.Api` keyword arguments. */
export interface FacadeEvaluateOptions {
  decisionModelId?: string;
  includeUnmatchedDetails?: boolean;
}

/**
 * Runtime namespace for Decision Model catalog and evaluation — mirrors
 * `BfwEngine.EngineFacade.Decisions`.
 */
export interface FacadeDecisions {
  list(): Promise<DecisionDefinition[]>;
  get(decisionDefinitionId: string): Promise<DecisionDefinition>;
  getLatestVersion(decisionDefinitionId: string): Promise<DecisionDefinition>;
  validate(xml: string): Promise<unknown>;
  deploy(sources: string[]): Promise<DmnDeployResponse>;
  evaluate(
    decisionDefinitionId: string,
    input: Record<string, unknown>,
    options?: FacadeEvaluateOptions,
  ): Promise<EvaluationResult>;
  evaluateByVersion(
    decisionDefinitionId: string,
    version: string,
    input: Record<string, unknown>,
    options?: FacadeEvaluateOptions,
  ): Promise<EvaluationResult>;
  evaluateService(
    decisionDefinitionId: string,
    serviceId: string,
    input: Record<string, unknown>,
    options?: { includeUnmatchedDetails?: boolean },
  ): Promise<DmnServiceEvaluationResult>;
  getVersions(decisionDefinitionId: string): Promise<DecisionDefinition[]>;
  getXml(decisionDefinitionId: string): Promise<string>;
  enable(decisionDefinitionId: string): Promise<void>;
  disable(decisionDefinitionId: string): Promise<void>;
  deleteVersion(decisionDefinitionId: string, version: string): Promise<void>;
  undeploy(decisionDefinitionId: string): Promise<void>;
}

/**
 * Runtime namespace for timer event trigger and cycle-schedule management —
 * mirrors `BfwEngine.EngineFacade.Timers`.
 */
export interface FacadeTimers {
  /**
   * Manually fires a waiting timer flow node instance. Resolves to
   * `{ triggered: true }` when a timer fired and `{ triggered: false }` when
   * the handler held no armed timer (not armed yet, already fired, or an
   * exhausted cycle). Not found, forbidden, not a timer event, and not
   * waiting reject.
   */
  triggerEvent(flowNodeInstanceId: string): Promise<TimerTriggerResult>;
  listSchedules(filters?: FacadeTimerScheduleFilters): Promise<TimerSchedule[]>;
  getSchedule(scheduleId: string): Promise<TimerSchedule>;
  enableSchedule(scheduleId: string): Promise<TimerSchedule>;
  disableSchedule(scheduleId: string): Promise<TimerSchedule>;
}
