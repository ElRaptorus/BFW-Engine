import { BfwEngineError } from './bfw-engine-error.js';

/** Thrown when a timer trigger is attempted on a flow node instance that is not a timer event. */
export class NotATimerEventError extends BfwEngineError {
  constructor(message: string, rawBody?: Record<string, unknown>) {
    super(422, 'not_a_timer_event', message, rawBody);
    this.name = 'NotATimerEventError';
  }
}
