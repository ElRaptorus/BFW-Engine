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
import type { MessageTriggerResult, SignalTriggerResult, TimerTriggerResult } from '../types/trigger.js';
import type { AuthProviderHandler } from './auth-provider.js';
import type { DataStoreAdapterHandler } from './data-store-adapter.js';
import type { EventSinkHandler, EventSinkOptions } from './event-sink.js';
import type { MonitoringPanelHandler } from './monitoring-panel.js';
import type { NamedScriptHandler } from './named-script-handler.js';
import type { PersistenceAdapterHandler } from './persistence-adapter.js';
import type { RestApiExtensionHandler } from './rest-api-extension.js';
import type { ServiceTaskHandler } from './service-task-handler.js';
import type { TimerSourceHandler } from './timer-source.js';

/**
 * This interface mirrors the in-BEAM Elixir `EvilEngine.EngineFacade` struct
 * passed to plugin `on_load` / `on_ready`. Sidecar host (gRPC) is deferred
 * (PLUG-D1). Stub capabilities (`TimerSource`, `MonitoringPanel`,
 * `DataStoreAdapter`, plugin `PersistenceAdapter`) may still be registered;
 * registration is accepted and unused at runtime — they are not in v1.
 *
 * Registration methods accept the handler instance directly so that
 * TypeScript enforces the handler contract at compile time.
 *
 * Runtime operations are grouped into resource-scoped namespaces
 * (processes, processInstances, userTasks, serviceTasks, decisions, timers, etc.).
 */
export interface EngineFacade {
  engineId: string;
  engineName: string;
  version: string;

  registerServiceTaskHandler(implementation: string, handler: ServiceTaskHandler): Promise<RegistrationResult>;
  registerNamedScript(scriptKey: string, handler: NamedScriptHandler): Promise<RegistrationResult>;
  registerPersistenceAdapter(adapterId: string, handler: PersistenceAdapterHandler): Promise<RegistrationResult>;
  registerRestApiExtension(prefix: string, handler: RestApiExtensionHandler): Promise<RegistrationResult>;
  registerMonitoringPanel(handler: MonitoringPanelHandler): Promise<RegistrationResult>;
  registerTimerSource(timerType: string, handler: TimerSourceHandler): Promise<RegistrationResult>;
  registerDataStoreAdapter(storeId: string, handler: DataStoreAdapterHandler): Promise<RegistrationResult>;
  registerAuthProvider(handler: AuthProviderHandler): Promise<RegistrationResult>;
  registerEventSink(name: string, handler: EventSinkHandler, options?: EventSinkOptions): Promise<RegistrationResult>;

  publishEvent(event: EngineEvent): Promise<void>;
  getConfig(key: string): Promise<unknown>;

  processes: FacadeProcesses;
  processInstances: FacadeProcessInstances;
  userTasks: FacadeUserTasks;
  serviceTasks: FacadeServiceTasks;
  flowNodeInstances: FacadeFlowNodeInstances;
  dataObjects: FacadeDataObjects;
  messages: FacadeMessages;
  signals: FacadeSignals;
  graphql: FacadeGraphql;
  adHocSubprocesses: FacadeAdHocSubprocesses;
  decisions: FacadeDecisions;
  timers: FacadeTimers;
}

/** Options for starting a process instance via the facade. */
export interface StartOptions {
  startEventId?: string;
  payload?: Record<string, unknown>;
  /** Immutable context variables accessible as `context.*` in FEEL expressions. Independent from the token payload. When omitted, the engine falls back to the payload for backward compatibility. */
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
    result: Record<string, unknown>,
    identity?: Identity,
  ): Promise<void>;
  cancel(processInstanceId: string, flowNodeInstanceId: string, reason?: string, identity?: Identity): Promise<void>;
}

export interface FacadeServiceTasks {
  finishAsync(flowNodeInstanceId: string, output: Record<string, unknown>): Promise<void>;
  failAsync(flowNodeInstanceId: string, errorCode: string, errorMessage: string): Promise<void>;
}

export interface FacadeFlowNodeInstances {
  get(id: string): Promise<FlowNodeInstance>;
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

export interface FacadeAdHocSubprocesses {
  getEnabledActivities(processInstanceId: string): Promise<AdHocActivity[]>;
  activateActivity(processInstanceId: string, activityId: string): Promise<AdHocActivateResult>;
  complete(processInstanceId: string): Promise<AdHocCompleteResult>;
  getStatus(processInstanceId: string): Promise<AdHocStatus>;
}

/**
 * Full typed GraphQL surface — mirrors GraphqlClient from @elraptorus/daemonengine_client
 * exactly, so plugin developers get the same typed query builder as SDK client
 * consumers. All query-builder types (field literals, filters, sorts, pagination,
 * includes) are imported from @elraptorus/daemonengine_sdk.
 */
export interface FacadeGraphql {
  queryProcessModels<F extends ProcessModelField>(
    options: ListQueryOptions<F, ProcessModelFilter, ProcessModelInclude>,
  ): Promise<PaginatedResult<Pick<ProcessModel, F>>>;

  getProcessModel<F extends ProcessModelField>(
    id: string,
    options: GetQueryOptions<F, ProcessModelInclude>,
  ): Promise<Pick<ProcessModel, F>>;

  queryProcessInstances<F extends ProcessInstanceField>(
    options: ListQueryOptions<F, ProcessInstanceFilter, ProcessInstanceInclude>,
  ): Promise<PaginatedResult<Pick<ProcessInstance, F>>>;

  getProcessInstance<F extends ProcessInstanceField>(
    id: string,
    options: GetQueryOptions<F, ProcessInstanceInclude>,
  ): Promise<Pick<ProcessInstance, F>>;

  queryFlowNodeInstances<F extends FlowNodeInstanceField>(
    options: ListQueryOptions<F, FlowNodeInstanceFilter, FlowNodeInstanceInclude>,
  ): Promise<PaginatedResult<Pick<FlowNodeInstance, F>>>;

  getFlowNodeInstance<F extends FlowNodeInstanceField>(
    id: string,
    options: GetQueryOptions<F, FlowNodeInstanceInclude>,
  ): Promise<Pick<FlowNodeInstance, F>>;

  queryDataObjectValues<F extends DataObjectValueField>(
    options: ListQueryOptions<F, DataObjectValueFilter, DataObjectValueInclude>,
  ): Promise<PaginatedResult<Pick<DataObjectValue, F>>>;

  getDataObjectValue<F extends DataObjectValueField>(
    id: string,
    options: GetQueryOptions<F, DataObjectValueInclude>,
  ): Promise<Pick<DataObjectValue, F>>;

  queryDataObjectHistory<F extends DataObjectValueField>(
    options: ListQueryOptions<F, DataObjectValueFilter, DataObjectValueInclude>,
  ): Promise<PaginatedResult<Pick<DataObjectValue, F>>>;

  queryProcessVersions<F extends ProcessVersionField>(
    options: ListQueryOptions<F, ProcessVersionFilter, Record<string, never>>,
  ): Promise<PaginatedResult<Pick<ProcessVersion, F>>>;

  queryDecisionVersions<F extends DecisionVersionField>(
    options: ListQueryOptions<F, DecisionVersionFilter, Record<string, never>>,
  ): Promise<PaginatedResult<Pick<DecisionVersion, F>>>;

  queryDecisionDefinitions<F extends DecisionDefinitionField>(
    options: ListQueryOptions<F, DecisionDefinitionFilter, DecisionDefinitionInclude>,
  ): Promise<PaginatedResult<Pick<DecisionDefinition, F>>>;

  getDecisionDefinition<F extends DecisionDefinitionField>(
    decisionDefinitionId: string,
    options: { fields: F[] },
  ): Promise<Pick<DecisionDefinition, F> | null>;

  raw<T = unknown>(query: string, variables?: Record<string, unknown>): Promise<T>;
}

export type RegistrationResult = { status: 'ok' } | { status: 'conflict'; incumbentPluginName: string };

/** Optional keyword filters for listing timer cycle schedules. */
export interface FacadeTimerScheduleFilters {
  processVersionId?: string;
  enabled?: boolean;
}

/** Optional evaluate options matching `EvilEngine.Api` keyword arguments. */
export interface FacadeEvaluateOptions {
  decisionModelId?: string;
  includeUnmatchedDetails?: boolean;
}

/**
 * Runtime namespace for Decision Model catalog and evaluation — mirrors
 * `EvilEngine.EngineFacade.Decisions`.
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
 * mirrors `EvilEngine.EngineFacade.Timers`.
 */
export interface FacadeTimers {
  triggerEvent(flowNodeInstanceId: string): Promise<TimerTriggerResult>;
  listSchedules(filters?: FacadeTimerScheduleFilters): Promise<TimerSchedule[]>;
  getSchedule(scheduleId: string): Promise<TimerSchedule>;
  enableSchedule(scheduleId: string): Promise<TimerSchedule>;
  disableSchedule(scheduleId: string): Promise<TimerSchedule>;
}
