import { DaemonEngineError } from './daemon-engine-error.js';

/** Thrown when the process has multiple start events and none was specified. */
export class AmbiguousStartEventError extends DaemonEngineError {
  constructor(message: string, rawBody?: Record<string, unknown>) {
    super(422, 'ambiguous_start_event', message, rawBody);
    this.name = 'AmbiguousStartEventError';
  }
}
