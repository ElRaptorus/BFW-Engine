import { BfwEngineError } from './bfw-engine-error.js';

/** Thrown when an evaluation is attempted on a disabled decision definition. */
export class DecisionDefinitionDisabledError extends BfwEngineError {
  constructor(message: string, rawBody?: Record<string, unknown>) {
    super(422, 'decision_definition_disabled', message, rawBody);
    this.name = 'DecisionDefinitionDisabledError';
  }
}
