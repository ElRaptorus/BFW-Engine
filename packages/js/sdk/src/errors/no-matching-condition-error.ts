import { DaemonEngineError } from './daemon-engine-error.js';

/** Thrown when a gateway split finds no matching condition expression and has no default flow. */
export class NoMatchingConditionError extends DaemonEngineError {
  constructor(message: string, rawBody?: Record<string, unknown>) {
    super(422, 'no_matching_condition', message, rawBody);
    this.name = 'NoMatchingConditionError';
  }
}
