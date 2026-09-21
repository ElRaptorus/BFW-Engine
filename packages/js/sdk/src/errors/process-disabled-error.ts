import { BfwEngineError } from './bfw-engine-error.js';

/** Thrown when attempting to start an instance on a disabled process. */
export class ProcessDisabledError extends BfwEngineError {
  constructor(message: string, rawBody?: Record<string, unknown>) {
    super(422, 'process_disabled', message, rawBody);
    this.name = 'ProcessDisabledError';
  }
}
