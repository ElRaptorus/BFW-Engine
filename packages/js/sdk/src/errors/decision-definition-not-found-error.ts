import { BfwEngineError } from './bfw-engine-error.js';

/** Thrown when the requested decision definition does not exist. */
export class DecisionDefinitionNotFoundError extends BfwEngineError {
  constructor(message: string, rawBody?: Record<string, unknown>) {
    super(404, 'decision_definition_not_found', message, rawBody);
    this.name = 'DecisionDefinitionNotFoundError';
  }
}
