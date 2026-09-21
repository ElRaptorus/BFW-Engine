import { BfwEngineError } from './bfw-engine-error.js';

export class DecisionServiceValidationError extends BfwEngineError {
  constructor(message: string, rawBody?: Record<string, unknown>) {
    super(422, 'decision_service_validation_error', message, rawBody);
    this.name = 'DecisionServiceValidationError';
  }
}
