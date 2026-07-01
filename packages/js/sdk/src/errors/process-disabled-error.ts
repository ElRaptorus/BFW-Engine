import { DaemonEngineError } from './daemon-engine-error.js';

/** Thrown when attempting to start an instance on a disabled process. */
export class ProcessDisabledError extends DaemonEngineError {
  constructor(message: string, rawBody?: Record<string, unknown>) {
    super(422, 'process_disabled', message, rawBody);
    this.name = 'ProcessDisabledError';
  }
}
