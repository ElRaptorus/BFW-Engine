import { BfwEngineError } from './bfw-engine-error.js';

/** Thrown when a multi-decision DMN model is evaluated without specifying which decision to target. */
export class AmbiguousDecisionError extends BfwEngineError {
  constructor(message: string, rawBody?: Record<string, unknown>) {
    super(422, 'ambiguous_decision', message, rawBody);
    this.name = 'AmbiguousDecisionError';
  }
}
