import type { AbortRequest, RetryRequest } from '@elraptorus/bfw_engine_sdk';

import type { HttpTransport } from '../http/transport.js';

/**
 * REST sub-client for `PUT/DELETE /process-instances/*` — abort, delete,
 * and retry operations on process instances.
 */
export class ProcessInstanceClient {
  constructor(private readonly transport: HttpTransport) {}

  /**
   * Abort a running process instance. All active FNIs are terminated
   * and the PI transitions to `aborted`.
   * @param id - Process instance UUID.
   * @param options - Optional abort reason.
   */
  async abort(id: string, options?: AbortRequest): Promise<void> {
    const encodedId = encodeURIComponent(id);
    await this.transport.put(`/process-instances/${encodedId}/abort`, options);
  }

  /**
   * Delete a terminal process instance and all its FNIs.
   * Only terminal PIs (finished, fatal, aborted) can be deleted.
   * @param id - Process instance UUID.
   */
  async delete(id: string): Promise<void> {
    const encodedId = encodeURIComponent(id);
    await this.transport.delete(`/process-instances/${encodedId}`);
  }

  /**
   * Retry a failed process instance (Phase 2).
   * @param id - Process instance UUID.
   * @param options - Optional retry configuration (target version, reset checkpoint).
   */
  async retry(id: string, options?: RetryRequest): Promise<void> {
    const encodedId = encodeURIComponent(id);
    await this.transport.put(`/process-instances/${encodedId}/retry`, options);
  }
}
