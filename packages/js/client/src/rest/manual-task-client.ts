import type { CancelManualTaskRequest } from '@elraptorus/bfw_engine_sdk';

import type { HttpTransport } from '../http/transport.js';

/** REST sub-client for `PUT /manual-tasks/*` — confirming and cancelling Manual Tasks that require confirmation. */
export class ManualTaskClient {
  constructor(private readonly transport: HttpTransport) {}

  /**
   * Confirm a waiting Manual Task. Sends no body: the token the task entered with passes through unchanged.
   * @param flowNodeInstanceId - The FNI UUID of the Manual Task.
   */
  async confirm(flowNodeInstanceId: string): Promise<void> {
    const encodedId = encodeURIComponent(flowNodeInstanceId);
    await this.transport.put(`/manual-tasks/${encodedId}/confirm`);
  }

  /**
   * Cancel a waiting Manual Task and abort the entire process instance.
   * @param flowNodeInstanceId - The FNI UUID of the Manual Task.
   * @param options - Optional cancellation reason.
   */
  async cancel(flowNodeInstanceId: string, options?: CancelManualTaskRequest): Promise<void> {
    const encodedId = encodeURIComponent(flowNodeInstanceId);
    await this.transport.put(`/manual-tasks/${encodedId}/cancel`, options);
  }
}
