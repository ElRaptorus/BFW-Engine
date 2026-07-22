import type {
  AdHocActivateResult,
  AdHocActivity,
  AdHocCompleteResult,
  AdHocStatus,
} from '@elraptorus/daemonengine_sdk';

import type { HttpTransport } from '../http/transport.js';

/**
 * REST sub-client for ad-hoc subprocess control.
 *
 * - Activities: `GET /adhoc-subprocesses/{id}/activities`
 * - Activate: `POST /adhoc-subprocesses/{id}/activities/{activityId}/activate`
 * - Complete: `POST /adhoc-subprocesses/{id}/complete`
 * - Status: `GET /adhoc-subprocesses/{id}/status`
 */
export class AdHocSubprocessClient {
  constructor(private readonly transport: HttpTransport) {}

  async getActivities(processInstanceId: string): Promise<AdHocActivity[]> {
    const response = await this.transport.get<{ data: AdHocActivity[] }>(
      `/adhoc-subprocesses/${encodeURIComponent(processInstanceId)}/activities`,
    );
    return response.data;
  }

  async activate(processInstanceId: string, activityId: string): Promise<AdHocActivateResult> {
    return this.transport.post<AdHocActivateResult>(
      `/adhoc-subprocesses/${encodeURIComponent(processInstanceId)}/activities/${encodeURIComponent(activityId)}/activate`,
      {},
    );
  }

  async complete(processInstanceId: string): Promise<AdHocCompleteResult> {
    return this.transport.post<AdHocCompleteResult>(
      `/adhoc-subprocesses/${encodeURIComponent(processInstanceId)}/complete`,
      {},
    );
  }

  async getStatus(processInstanceId: string): Promise<AdHocStatus> {
    return this.transport.get<AdHocStatus>(`/adhoc-subprocesses/${encodeURIComponent(processInstanceId)}/status`);
  }
}
