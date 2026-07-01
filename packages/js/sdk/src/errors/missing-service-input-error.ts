import { DaemonEngineError } from './daemon-engine-error.js';

/** Thrown when a required `inputData` entry is not provided for a Decision Service evaluation. */
export class MissingServiceInputError extends DaemonEngineError {
  constructor(
    message: string,
    /** Names of the missing required inputs. */
    public readonly missingInputs: string[],
    rawBody?: Record<string, unknown>,
  ) {
    super(422, 'missing_service_input', message, rawBody);
    this.name = 'MissingServiceInputError';
  }
}
