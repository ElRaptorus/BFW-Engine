import { BfwEngineError } from './bfw-engine-error.js';

/** Thrown when the specified start event ID does not exist in the process. */
export class StartEventNotFoundError extends BfwEngineError {
  constructor(message: string, rawBody?: Record<string, unknown>) {
    super(422, 'start_event_not_found', message, rawBody);
    this.name = 'StartEventNotFoundError';
  }
}
