import type { EngineFacade } from './engine-facade.js';

/**
 * Handler interface for Service Task plugins.
 *
 * **Async-only contract:** `handleEnter` must return either
 * `{ status: 'async' }` (the handler has started background work and will
 * complete the FNI later via `facade.serviceTasks.finishAsync` /
 * `facade.serviceTasks.failAsync`) or `{ status: 'error'; reason }` for
 * synchronous startup failures. Returning a synchronous result is not
 * supported — use a Named Script (`NamedScriptHandler`) for local,
 * engine-internal computation that completes immediately.
 *
 * `finishAsync` / `failAsync` may be called before `handleEnter` has
 * resolved: the engine holds the call until the flow node instance is
 * parked in `waiting`, then answers it.
 *
 * **Engine restart:** background work does not survive a restart. When a
 * process instance resumes, each of its Service Task flow node instances that
 * is still `waiting` stays `waiting` and the engine publishes
 * `PluginAsyncFlowNodeRehydrated`. If the handler implements the optional
 * `handleResume`, the engine then calls it; the handler decides whether to
 * re-issue the work or end the task with `finishAsync` / `failAsync`.
 */
export interface ServiceTaskHandler {
  handleEnter(input: ServiceTaskInput, facade: EngineFacade): Promise<ServiceTaskResult>;

  /**
   * Optional. Called once for each resumed Service Task flow node instance
   * that is still `waiting` after an engine restart. Its result is ignored; a
   * rejection is logged and leaves the task `waiting`. Without this method the
   * task stays `waiting` until something completes it.
   */
  handleResume?(input: ServiceTaskResumeInput, facade: EngineFacade): Promise<void>;
}

/** Input provided to a service task handler when the engine enters the task. */
export interface ServiceTaskInput {
  flowNodeInstanceId: string;
  processInstanceId: string;
  flowNodeId: string;
  inputToken: Record<string, unknown>;
  typeProperties: Record<string, unknown>;
}

/** What a resumed Service Task was parked with. */
export interface ServiceTaskResumeInput {
  flowNodeInstanceId: string;
  processInstanceId: string;
  flowNodeId: string;
  /** The task's `implementation` attribute (the handler's dispatch key). */
  implementation: string;
  /** The input after `bfw:inputMapping`, as `handleEnter` received it in `inputToken`. */
  mappedInput: Record<string, unknown>;
  /** The flow node's type-specific properties, as in `ServiceTaskInput`. */
  typeProperties: Record<string, unknown>;
}

/**
 * Result returned by a service task handler.
 *
 * Per the async-only contract, only `async` and `error` are valid.
 * The handler must call `facade.serviceTasks.finishAsync` or
 * `facade.serviceTasks.failAsync` to complete the flow node instance.
 */
export type ServiceTaskResult = { status: 'async' } | { status: 'error'; reason: string };
