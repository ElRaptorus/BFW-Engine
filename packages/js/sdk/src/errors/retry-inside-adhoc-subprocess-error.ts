import { BfwEngineError } from './bfw-engine-error.js';

/** Thrown when attempting to retry a process instance that is a child of an ad-hoc subprocess scope. */
export class RetryInsideAdhocSubprocessError extends BfwEngineError {
  constructor(message: string, rawBody?: Record<string, unknown>) {
    super(422, 'retry_inside_adhoc_subprocess', message, rawBody);
    this.name = 'RetryInsideAdhocSubprocessError';
  }
}
