import { BfwEngineError } from './bfw-engine-error.js';

/**
 * Thrown when the engine is temporarily unavailable (HTTP 503, not capacity):
 * `service_unavailable` (resuming, or the database is unavailable) or
 * `engine_shutting_down` (the engine is stopping and starts no process instances).
 */
export class ServiceUnavailableError extends BfwEngineError {
  constructor(message: string, rawBody?: Record<string, unknown>, errorCode = 'service_unavailable') {
    super(503, errorCode, message, rawBody);
    this.name = 'ServiceUnavailableError';
  }
}
