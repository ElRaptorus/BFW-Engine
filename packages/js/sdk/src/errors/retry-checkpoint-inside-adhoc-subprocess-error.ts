import { BfwEngineError } from './bfw-engine-error.js';

/** Thrown when a retry checkpoint targets a flow node instance inside an ad-hoc subprocess scope. */
export class RetryCheckpointInsideAdhocSubprocessError extends BfwEngineError {
  constructor(message: string, rawBody?: Record<string, unknown>) {
    super(422, 'retry_checkpoint_inside_adhoc_subprocess', message, rawBody);
    this.name = 'RetryCheckpointInsideAdhocSubprocessError';
  }
}
