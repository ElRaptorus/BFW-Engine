import { BfwEngineError } from './bfw-engine-error.js';

/** Thrown when payload or result contract validation fails. */
export class ContractViolationError extends BfwEngineError {
  constructor(
    message: string,
    public readonly violations: { message: string; path: string[] }[],
    rawBody?: Record<string, unknown>,
  ) {
    super(422, 'contract_violation', message, rawBody);
    this.name = 'ContractViolationError';
  }
}
