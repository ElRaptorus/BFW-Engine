import { DaemonEngineError } from './daemon-engine-error.js';

/** Thrown when a retry checkpoint targets a flow node instance inside a cancelled Transaction subprocess scope. */
export class RetryCheckpointInsideTransactionError extends DaemonEngineError {
  constructor(message: string, rawBody?: Record<string, unknown>) {
    super(422, 'retry_checkpoint_inside_transaction', message, rawBody);
    this.name = 'RetryCheckpointInsideTransactionError';
  }
}
