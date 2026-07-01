import { DaemonEngineError } from './daemon-engine-error.js';

/** Thrown when the engine rejects the request due to validation failures (HTTP 422). */
export class ValidationError extends DaemonEngineError {
  constructor(
    message: string,
    /** Individual field-level validation failures, if provided by the engine. */
    public readonly failures: unknown[],
    rawBody?: Record<string, unknown>,
  ) {
    super(422, 'validation_error', message, rawBody);
    this.name = 'ValidationError';
  }
}
