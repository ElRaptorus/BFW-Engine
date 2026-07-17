import { DaemonEngineError } from './daemon-engine-error.js';

/** Thrown when a retry checkpoint targets an MI/Loop iteration FNI instead of the shell. */
export class RetryCheckpointIsMiIterationError extends DaemonEngineError {
  constructor(message: string, rawBody?: Record<string, unknown>) {
    super(422, 'retry_checkpoint_is_mi_iteration', message, rawBody);
    this.name = 'RetryCheckpointIsMiIterationError';
  }
}
