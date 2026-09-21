import { BfwEngineError } from './bfw-engine-error.js';

/** Thrown when the engine is temporarily unavailable (HTTP 503, not capacity). */
export class ServiceUnavailableError extends BfwEngineError {
  constructor(message: string, rawBody?: Record<string, unknown>) {
    super(503, 'service_unavailable', message, rawBody);
    this.name = 'ServiceUnavailableError';
  }
}
