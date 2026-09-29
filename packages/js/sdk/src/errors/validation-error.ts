import { BfwEngineError } from './bfw-engine-error.js';

/** Thrown when the engine rejects the request due to validation failures (HTTP 422). */
export class ValidationError extends BfwEngineError {
  constructor(
    message: string,
    /** Individual field-level validation failures, if provided by the engine. */
    public readonly failures: unknown[],
    rawBody?: Record<string, unknown>,
    errorCode = 'validation_error',
  ) {
    super(422, errorCode, message, rawBody);
    this.name = 'ValidationError';
  }
}
