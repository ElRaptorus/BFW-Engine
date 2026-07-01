import { DaemonEngineError } from './daemon-engine-error.js';

/** Thrown when the requested resource does not exist (HTTP 404). */
export class NotFoundError extends DaemonEngineError {
  constructor(message: string, rawBody?: Record<string, unknown>) {
    super(404, 'not_found', message, rawBody);
    this.name = 'NotFoundError';
  }
}
