import type { ProcessInstanceState } from '../types/enums.js';
import { BfwEngineError } from './bfw-engine-error.js';

/** Thrown when an operation targets a PI that has already reached a terminal state. */
export class ProcessInstanceAlreadyTerminalError extends BfwEngineError {
  constructor(
    message: string,
    public readonly currentState: ProcessInstanceState,
    rawBody?: Record<string, unknown>,
  ) {
    super(422, 'process_already_terminal', message, rawBody);
    this.name = 'ProcessInstanceAlreadyTerminalError';
  }
}
