import type { CancelUserTaskRequest, FinishUserTaskRequest } from '@elraptorus/daemonengine_sdk';

import type { HttpTransport } from '../http/transport.js';

/** REST sub-client for `PUT /user-tasks/*` — completing and cancelling user tasks. */
export class UserTaskClient {
  constructor(private readonly transport: HttpTransport) {}

  /**
   * Complete a user task with a result payload.
   * @param flowNodeInstanceId - The FNI UUID of the user task.
   * @param options - Optional result payload.
   */
  async finish(flowNodeInstanceId: string, options?: FinishUserTaskRequest): Promise<void> {
    const encodedId = encodeURIComponent(flowNodeInstanceId);
    await this.transport.put(`/user-tasks/${encodedId}/finish`, options);
  }

  /**
   * Cancel a user task and abort the entire process instance.
   * Has the same effect as aborting the PI directly.
   * @param flowNodeInstanceId - The FNI UUID of the user task.
   * @param options - Optional cancellation reason.
   */
  async cancel(flowNodeInstanceId: string, options?: CancelUserTaskRequest): Promise<void> {
    const encodedId = encodeURIComponent(flowNodeInstanceId);
    await this.transport.put(`/user-tasks/${encodedId}/cancel`, options);
  }
}
