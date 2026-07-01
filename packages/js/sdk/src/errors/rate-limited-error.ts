import { DaemonEngineError } from './daemon-engine-error.js';

/** Thrown when the engine rate-limits the request (HTTP 429). */
export class RateLimitedError extends DaemonEngineError {
  constructor(
    /** Seconds until the client should retry. */
    public readonly retryAfterSeconds: number,
    message: string,
    rawBody?: Record<string, unknown>,
  ) {
    super(429, 'rate_limited', message, rawBody);
    this.name = 'RateLimitedError';
  }
}
