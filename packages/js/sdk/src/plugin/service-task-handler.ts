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
 */
export interface ServiceTaskHandler {
  handleEnter(input: ServiceTaskInput, facade: EngineFacade): Promise<ServiceTaskResult>;
}

/** Input provided to a service task handler when the engine enters the task. */
export interface ServiceTaskInput {
  flowNodeInstanceId: string;
  processInstanceId: string;
  flowNodeId: string;
  inputToken: Record<string, unknown>;
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
