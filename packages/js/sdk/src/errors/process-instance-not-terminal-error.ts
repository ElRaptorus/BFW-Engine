import type { ProcessInstanceState } from '../types/enums.js';
import { DaemonEngineError } from './daemon-engine-error.js';

/** Thrown when an operation requires a terminal PI but it is not terminal. */
export class ProcessInstanceNotTerminalError extends DaemonEngineError {
  constructor(
    message: string,
    public readonly currentState: ProcessInstanceState,
    rawBody?: Record<string, unknown>,
  ) {
    super(422, 'process_instance_not_terminal', message, rawBody);
    this.name = 'ProcessInstanceNotTerminalError';
  }
}
