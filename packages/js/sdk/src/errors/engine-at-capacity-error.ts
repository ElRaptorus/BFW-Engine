import { BfwEngineError } from './bfw-engine-error.js';

/** Thrown when the engine rejects new work because it has reached its active PI limit. */
export class EngineAtCapacityError extends BfwEngineError {
  constructor(
    /** Number of currently active process instances. */
    public readonly active: number,
    /** Configured PI limit, or null if unlimited. */
    public readonly limit: number | null,
    /** Seconds until the client should retry. */
    public readonly retryAfterSeconds: number,
    message: string,
    rawBody?: Record<string, unknown>,
  ) {
    super(503, 'engine_at_capacity', message, rawBody);
    this.name = 'EngineAtCapacityError';
  }
}
