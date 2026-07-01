/** Request body for `PUT /user-tasks/:id/finish`. */
export interface FinishUserTaskRequest {
  /** Optional result payload to merge into the output token. */
  result?: Record<string, unknown>;
}

/** Request body for `PUT /user-tasks/:id/cancel`. */
export interface CancelUserTaskRequest {
  /** Optional human-readable cancellation reason. */
  reason?: string;
}
