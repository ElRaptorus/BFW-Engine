import { DaemonEngineError } from './daemon-engine-error.js';

/**
 * Thrown when the request payload exceeds the engine's configured token size limit.
 * Unified shape per 2026-05-07 decision: `{ field, size, limit }`.
 */
export class PayloadTooLargeError extends DaemonEngineError {
  constructor(
    /** Which field exceeded the limit (e.g. "payload", "result"). */
    public readonly field: string,
    /** Actual payload size in bytes. */
    public readonly size: number,
    /** Configured maximum size in bytes. */
    public readonly limit: number,
    rawBody?: Record<string, unknown>,
  ) {
    super(413, 'payload_too_large', `Payload field '${field}' size ${size} exceeds limit ${limit}`, rawBody);
    this.name = 'PayloadTooLargeError';
  }
}
