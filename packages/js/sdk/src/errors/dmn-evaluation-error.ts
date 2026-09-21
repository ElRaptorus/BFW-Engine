import { BfwEngineError } from './bfw-engine-error.js';

/** Thrown when DMN evaluation fails (e.g. hit policy violation, FEEL error). */
export class DmnEvaluationError extends BfwEngineError {
  constructor(
    message: string,
    public readonly decisionModelId: string | null,
    public readonly details: string | null,
    rawBody?: Record<string, unknown>,
  ) {
    super(422, 'dmn_evaluation_error', message, rawBody);
    this.name = 'DmnEvaluationError';
  }
}
