import { BfwEngineError } from './bfw-engine-error.js';

/** Thrown when a DMN definitions document contains no decision elements. */
export class NoDecisionsError extends BfwEngineError {
  constructor(message: string, rawBody?: Record<string, unknown>) {
    super(422, 'no_decisions', message, rawBody);
    this.name = 'NoDecisionsError';
  }
}
