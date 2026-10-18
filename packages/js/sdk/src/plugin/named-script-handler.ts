import type { EngineFacade } from './engine-facade.js';

/** Handler interface for named script plugins. */
export interface NamedScriptHandler {
  handleEnter(input: NamedScriptInput, facade: EngineFacade): Promise<NamedScriptResult>;
}

/** Input provided to a named script handler. */
export interface NamedScriptInput {
  flowNodeInstanceId: string;
  processInstanceId: string;
  flowNodeId: string;
  inputPayload: Record<string, unknown>;
  context: Record<string, unknown>;
  /**
   * `true` when the engine runs the script again after a restart because its
   * flow node instance was still `active`. Use it to make side effects
   * idempotent.
   */
  resumed?: boolean;
}

/** Result returned by a named script handler. */
export type NamedScriptResult =
  | { status: 'completed'; output: Record<string, unknown> }
  | { status: 'error'; reason: string };
