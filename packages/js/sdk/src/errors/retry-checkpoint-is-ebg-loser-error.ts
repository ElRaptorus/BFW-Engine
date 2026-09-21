import { BfwEngineError } from './bfw-engine-error.js';

/** Thrown when a retry checkpoint targets an Event-Based Gateway loser FNI. */
export class RetryCheckpointIsEbgLoserError extends BfwEngineError {
  constructor(message: string, rawBody?: Record<string, unknown>) {
    super(422, 'retry_checkpoint_is_ebg_loser', message, rawBody);
    this.name = 'RetryCheckpointIsEbgLoserError';
  }
}
