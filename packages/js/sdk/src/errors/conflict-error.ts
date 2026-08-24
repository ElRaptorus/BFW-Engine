import { DaemonEngineError } from './daemon-engine-error.js';

/** Thrown on HTTP 409 conflicts (for example a timer that is not currently triggerable). */
export class ConflictError extends DaemonEngineError {
  constructor(message: string, rawBody?: Record<string, unknown>) {
    super(409, 'conflict', message, rawBody);
    this.name = 'ConflictError';
  }
}
