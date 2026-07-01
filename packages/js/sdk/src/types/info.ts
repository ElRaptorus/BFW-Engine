/** Response body for `GET /info`. Does not require authentication. */
export interface EngineInfoResponse {
  /** Unique engine instance identifier. */
  engineId: string;
  /** Human-readable engine name. */
  engineName: string;
  /** Engine version string. */
  version: string;
  /** ISO 8601 timestamp when the engine was started. */
  startedAt: string;
}
