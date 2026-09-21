import type { FlowNodeInstanceState } from '../types/enums.js';
import { BfwEngineError } from './bfw-engine-error.js';

/**
 * Thrown when a user-task or async-FNI operation targets an FNI in the wrong state.
 *
 * The engine may return several error codes for this condition:
 * `fni_not_waiting`, `fni_already_finished`, `fni_already_aborted`,
 * `fni_already_interrupted`, `fni_already_fatal`. All are mapped to this class
 * with the actual wire error code preserved in `errorCode`.
 */
export class FniNotWaitingError extends BfwEngineError {
  constructor(
    message: string,
    public readonly currentState: FlowNodeInstanceState,
    errorCode: string = 'fni_not_waiting',
    rawBody?: Record<string, unknown>,
  ) {
    super(422, errorCode, message, rawBody);
    this.name = 'FniNotWaitingError';
  }
}
