import { BfwEngineError } from './bfw-engine-error.js';

/** Thrown when the authenticated identity lacks permission for the requested action (HTTP 403). */
export class ForbiddenError extends BfwEngineError {
  constructor(
    public readonly requiredClaim: string,
    public readonly requiredValue: string,
    public readonly resource: 'process' | 'process_instance' | 'decision' | 'message' | 'signal',
    message: string,
    rawBody?: Record<string, unknown>,
  ) {
    super(403, 'forbidden', message, rawBody);
    this.name = 'ForbiddenError';
  }
}
