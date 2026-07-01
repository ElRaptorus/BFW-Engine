import { DaemonEngineError } from './daemon-engine-error.js';

/** Thrown when a PI cannot be retried (Phase 2). */
export class ProcessInstanceNotRetriableError extends DaemonEngineError {
  constructor(message: string, rawBody?: Record<string, unknown>) {
    super(422, 'process_instance_not_retriable', message, rawBody);
    this.name = 'ProcessInstanceNotRetriableError';
  }
}
