import { BfwEngineError } from './bfw-engine-error.js';

/** Thrown when an input value does not satisfy the `inputValues` constraint on a decision table column. */
export class InputValueViolationError extends BfwEngineError {
  constructor(
    message: string,
    /** The DMN input element ID whose constraint was violated. */
    public readonly inputId: string | null,
    rawBody?: Record<string, unknown>,
  ) {
    super(422, 'input_value_violation', message, rawBody);
    this.name = 'InputValueViolationError';
  }
}
