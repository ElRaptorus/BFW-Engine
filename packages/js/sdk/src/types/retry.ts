/** Request body for `PUT /process-instances/:id/retry` (Phase 2). */
export interface RetryRequest {
  /**
   * Target process version to migrate to. Omit to retry on the same version.
   * `"latest"` resolves to the most recently deployed enabled version.
   */
  version?: string;
  /**
   * Reset the PI to this FNI checkpoint (delete all FNIs created after it).
   * v1 of the engine defers this.
   */
  resetToFlowNodeInstanceId?: string;
}
