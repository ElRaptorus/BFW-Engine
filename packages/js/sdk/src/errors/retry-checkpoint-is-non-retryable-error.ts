import { BfwEngineError } from './bfw-engine-error.js';

/**
 * Thrown when a retry checkpoint targets an FNI interrupted by a BPMN flow
 * mechanism (boundary cancellation, Event-Based Gateway, or Terminate/Error End).
 */
export class RetryCheckpointIsNonRetryableError extends BfwEngineError {
  constructor(message: string, rawBody?: Record<string, unknown>) {
    super(422, 'retry_checkpoint_is_non_retryable', message, rawBody);
    this.name = 'RetryCheckpointIsNonRetryableError';
  }
}
