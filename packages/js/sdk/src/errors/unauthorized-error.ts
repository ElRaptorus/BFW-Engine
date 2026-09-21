import { BfwEngineError } from './bfw-engine-error.js';

/**
 * Thrown when the JWT is missing, expired, or invalid (HTTP 401).
 * Per S-7, the engine intentionally omits the failure reason for invalid
 * tokens — only missing-header cases include a `message` field.
 */
export class UnauthorizedError extends BfwEngineError {
  constructor(message?: string, rawBody?: Record<string, unknown>) {
    super(401, 'unauthorized', message ?? 'unauthorized', rawBody);
    this.name = 'UnauthorizedError';
  }
}
