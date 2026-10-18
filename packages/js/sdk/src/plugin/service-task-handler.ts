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
 * resolved: the engine accepts the call at once and applies the result when
 * the flow node instance is parked in `waiting`. If the task ends another way
 * first (for example `handleEnter` returns an error), the result is dropped.
 * A second early call for the same task is rejected with `fni_not_waiting`.
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
   * Optional. A TypeScript plugin host (BFW-Engine-Lite) calls it once after
   * a restart for each Service Task flow node instance that is still
   * `waiting` on this handler's async work. The handler re-attaches (polls
   * the external job again, resends the request) or ends the task with
   * `finishAsync` / `failAsync`. Its result is ignored; a rejection fails the
   * task with error code `handler_resume_raised`, which Error Boundaries can
   * catch. Without this method the task stays `waiting` until something
   * completes it. The Elixir Engine calls the Elixir `handle_resume/2`
   * callback instead.
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
  /**
   * `true` when the engine enters the task again after a restart because its
   * flow node instance was still `active` (its start had not been parked).
   * Use it to make the start idempotent.
   */
  resumed?: boolean;
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
