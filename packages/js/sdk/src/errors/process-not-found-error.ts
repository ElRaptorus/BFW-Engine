import { DaemonEngineError } from './daemon-engine-error.js';

/** Thrown when the requested process does not exist. */
export class ProcessNotFoundError extends DaemonEngineError {
  constructor(message: string, rawBody?: Record<string, unknown>) {
    super(404, 'process_not_found', message, rawBody);
    this.name = 'ProcessNotFoundError';
  }
}
