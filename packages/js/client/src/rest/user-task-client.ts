import type { CancelUserTaskRequest, FinishUserTaskRequest } from '@elraptorus/bfw_engine_sdk';

import type { HttpTransport } from '../http/transport.js';

/**
 * REST sub-client for `PUT /user-tasks/*` — completing and cancelling User Tasks.
 * These routes accept User Tasks only; use {@link ManualTaskClient} for Manual Tasks.
 */
export class UserTaskClient {
  constructor(private readonly transport: HttpTransport) {}

  /**
   * Complete a User Task. The Engine writes `{ actionId, values }` as the task token,
   * replacing the input token. There is no merge.
   * @param flowNodeInstanceId - The FNI UUID of the User Task.
   * @param options - Optional action id and field values.
   */
  async finish(flowNodeInstanceId: string, options?: FinishUserTaskRequest): Promise<void> {
    const encodedId = encodeURIComponent(flowNodeInstanceId);
    await this.transport.put(`/user-tasks/${encodedId}/finish`, options);
  }

  /**
   * Cancel a User Task and abort the entire process instance.
   * Has the same effect as aborting the PI directly.
   * @param flowNodeInstanceId - The FNI UUID of the User Task.
   * @param options - Optional cancellation reason.
   */
  async cancel(flowNodeInstanceId: string, options?: CancelUserTaskRequest): Promise<void> {
    const encodedId = encodeURIComponent(flowNodeInstanceId);
    await this.transport.put(`/user-tasks/${encodedId}/cancel`, options);
  }
}
