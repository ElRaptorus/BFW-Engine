import { BfwEngineError } from './bfw-engine-error.js';

export class DecisionServiceNotFoundError extends BfwEngineError {
  constructor(message: string, rawBody?: Record<string, unknown>) {
    super(404, 'service_not_found', message, rawBody);
    this.name = 'DecisionServiceNotFoundError';
  }
}
