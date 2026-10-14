import { BfwEngineError } from './bfw-engine-error.js';

/** One rejected source of a deploy request, as listed in the `failures` array of a 422 deploy body. */
export interface DeployFailure {
  /** Name of the rejected source, `source_<n>.bpmn` with a 1-based batch position. */
  file: string;
  /** Human-readable validation messages for that source. */
  details: string[];
}

/** Thrown when BPMN deploy validation fails. Distinct from generic ValidationError. */
export class DeployValidationFailedError extends BfwEngineError {
  constructor(
    message: string,
    /** Per-source validation failures from the engine's 422 deploy body; empty when the body carries none. */
    public readonly failures: readonly DeployFailure[] = [],
    rawBody?: Record<string, unknown>,
  ) {
    super(422, 'validation_failed', message, rawBody);
    this.name = 'DeployValidationFailedError';
  }
}
