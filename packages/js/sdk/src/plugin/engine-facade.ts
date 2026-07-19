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
import type { DataObjectValue } from '../types/data-object-value.js';
import type { DecisionDefinition } from '../types/decision-definition.js';
import type { DecisionVersion } from '../types/decision-version.js';
import type { DeployResponse } from '../types/deploy.js';
import type { FlowNodeInstance } from '../types/flow-node-instance.js';
import type { Identity } from '../types/identity.js';
import type { ProcessInstance } from '../types/process-instance.js';
import type { ProcessModel } from '../types/process-model.js';
import type { ProcessVersion } from '../types/process-version.js';
import type { StartResult } from '../types/start.js';
import type { MessageTriggerResult, SignalTriggerResult } from '../types/trigger.js';
import type { AdHocActivateResult, AdHocActivity, AdHocCompleteResult, AdHocStatus } from '../types/adhoc-subprocess.js';
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
 * This interface mirrors the Elixir `EvilEngine.Api` module,
 * which is the single shared service layer through which all wire
 * adapters and plugins converge. The facade is fully implemented — all REST
 * controllers, GraphQL resolvers, and plugin handlers call through
 * `EvilEngine.Api` exclusively. The gRPC sidecar contract will be a
 * 1:1 projection of this surface.
 *
 * Registration methods accept the handler instance directly so that
 * TypeScript enforces the handler contract at compile time. The gRPC
 * bridge serializes handler calls over the wire transparently.
 *
 * Runtime operations are grouped into resource-scoped namespaces
 * (processes, processInstances, userTasks, serviceTasks, etc.) so
 * plugins get typed access to all EvilEngine.Api operations without
 * direct module coupling.
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
  get(processModelId: string): Promise<ProcessModel>;
  getLatestVersion(processModelId: string): Promise<ProcessModel>;
  deploy(sources: string[]): Promise<DeployResponse>;
  enable(processModelId: string): Promise<void>;
  disable(processModelId: string): Promise<void>;
  deleteVersion(processModelId: string, version: string): Promise<void>;
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
