import { DaemonEngineError } from './daemon-engine-error.js';

/** Explicit 500 subclass for engine-internal errors. */
export class InternalEngineError extends DaemonEngineError {
  constructor(message: string, rawBody?: Record<string, unknown>) {
    super(500, 'internal_error', message, rawBody);
    this.name = 'InternalEngineError';
  }
}
