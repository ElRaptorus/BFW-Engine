import { DaemonEngineError } from './daemon-engine-error.js';

/** Thrown when the process has no start event at all. */
export class NoStartEventError extends DaemonEngineError {
  constructor(message: string, rawBody?: Record<string, unknown>) {
    super(422, 'no_start_event', message, rawBody);
    this.name = 'NoStartEventError';
  }
}
