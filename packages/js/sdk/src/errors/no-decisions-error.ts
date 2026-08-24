import { DaemonEngineError } from './daemon-engine-error.js';

/** Thrown when a DMN definitions document contains no decision elements. */
export class NoDecisionsError extends DaemonEngineError {
  constructor(message: string, rawBody?: Record<string, unknown>) {
    super(422, 'no_decisions', message, rawBody);
    this.name = 'NoDecisionsError';
  }
}
