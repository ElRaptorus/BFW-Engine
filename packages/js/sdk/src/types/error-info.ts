/**
 * Structured error details for fatal or aborted process/flow-node instances
 * and for `FlowNodeInstanceFinished` WebSocket events.
 *
 * Keys are **snake_case** throughout — this object is an opaque payload and
 * is not camelCased by the Wire layer.
 */
export interface ErrorInfo {
  /**
   * Programmatic error key for client-side branching (for example
   * `"in_mapping_failed"`, `"contract_violation"`).
   */
  error_code: string;
  /** Human-readable diagnostic sentence suitable for display in the UI. */
  message: string;
  /**
   * Optional structured context. May be a string, object, or array depending
   * on the error source. Omitted when no extra detail is available.
   */
  detail?: string | Record<string, unknown> | unknown[] | null;
}
