import { BfwEngineError } from './bfw-engine-error.js';

export class DmnCycleError extends BfwEngineError {
  constructor(
    message: string,
    public readonly decisionIds: string[],
    rawBody?: Record<string, unknown>,
  ) {
    super(422, 'dmn_cycle_error', message, rawBody);
    this.name = 'DmnCycleError';
  }
}
