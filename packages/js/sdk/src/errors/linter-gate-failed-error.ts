import { BfwEngineError } from './bfw-engine-error.js';

/** Thrown when the deploy-time linter gate rejects the process. */
export class LinterGateFailedError extends BfwEngineError {
  constructor(message: string, rawBody?: Record<string, unknown>) {
    super(422, 'linter_gate_failed', message, rawBody);
    this.name = 'LinterGateFailedError';
  }
}
