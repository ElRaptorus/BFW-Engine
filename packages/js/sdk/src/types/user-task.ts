/**
 * Request body for `PUT /user-tasks/:id/finish` (User Tasks only).
 *
 * The Engine writes this shape as the task's token, replacing the input token.
 * There is no merge. Absent `actionId` is stored as `null`. Absent or `null`
 * `values` is stored as `{}`.
 */
export interface FinishUserTaskRequest {
  /** Pressed action id. Absent, or a non-blank string of at most 255 characters. */
  actionId?: string;
  /** Field values keyed by form field id. */
  values?: Record<string, unknown>;
}

/**
 * Token a User Task writes before output mappings.
 *
 * Output mappings see it as FEEL `token` (`token.actionId`, `token.values.<fieldId>`).
 * The result contract checks the mapped output, which is this token when the task has no output mappings.
 */
export interface UserTaskResultToken {
  actionId: string | null;
  values: Record<string, unknown>;
}

/** Request body for `PUT /user-tasks/:id/cancel` (User Tasks only). */
export interface CancelUserTaskRequest {
  /** Optional human-readable cancellation reason. */
  reason?: string;
}

/** Request body for `PUT /manual-tasks/:id/cancel`. */
export interface CancelManualTaskRequest {
  /** Optional human-readable cancellation reason. */
  reason?: string;
}
