/**
 * Base error thrown by the client when the engine returns a non-2xx HTTP response.
 * Subclasses provide typed access to error-specific properties.
 * Use `instanceof` to narrow to a specific error type.
 */
export class BfwEngineError extends Error {
  constructor(
    /** HTTP status code from the engine response. */
    public readonly statusCode: number,
    /** The `error` field from the engine's JSON response body. */
    public readonly errorCode: string,
    message: string,
    /** Raw response body for cases where the consumer needs fields not covered by a subclass. */
    public readonly rawBody?: Record<string, unknown>,
  ) {
    super(message);
    this.name = 'BfwEngineError';
  }
}
