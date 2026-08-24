import { DaemonEngineError } from './daemon-engine-error.js';

/** Thrown when an inner activity dispatch inside an ad-hoc subprocess fails. */
export class DispatchFailedError extends DaemonEngineError {
  constructor(message: string, rawBody?: Record<string, unknown>) {
    super(500, 'dispatch_failed', message, rawBody);
    this.name = 'DispatchFailedError';
  }
}
