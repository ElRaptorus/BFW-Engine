import type { ProcessInstanceState } from '../types/enums.js';
import { DaemonEngineError } from './daemon-engine-error.js';

/** Thrown when an operation targets a PI that has already reached a terminal state. */
export class ProcessInstanceAlreadyTerminalError extends DaemonEngineError {
  constructor(
    message: string,
    public readonly currentState: ProcessInstanceState,
    rawBody?: Record<string, unknown>,
  ) {
    super(422, 'process_already_terminal', message, rawBody);
    this.name = 'ProcessInstanceAlreadyTerminalError';
  }
}
