import type { EngineInfoResponse, StatsResponse } from '@elraptorus/bfw_engine_sdk';

import type { HttpTransport } from '../http/transport.js';

/** REST sub-client for `GET /health`, `GET /info`, `GET /stats`, `GET /metrics` — engine introspection. */
export class EngineClient {
  constructor(private readonly transport: HttpTransport) {}

  /**
   * Liveness probe. Resolves if the engine is reachable (HTTP 204), rejects otherwise.
   * Does not require authentication. No response body.
   */
  async health(): Promise<void> {
    await this.transport.head('/health', { skipAuth: true, expect: 204 });
  }

  /** Engine identity and version. Does not require authentication. */
  async info(): Promise<EngineInfoResponse> {
    return this.transport.get<EngineInfoResponse>('/info', { skipAuth: true });
  }

  /**
   * Full engine state snapshot: process counts, PI state distribution,
   * active FNIs, pending user tasks, armed timers, loaded plugins.
   */
  async stats(): Promise<StatsResponse> {
    return this.transport.get<StatsResponse>('/stats');
  }

  /**
   * Prometheus exposition format metrics. Returns raw text, not JSON.
   * Does not require authentication. Returns `null` if metrics are disabled (404).
   */
  async metrics(): Promise<string | null> {
    return this.transport.getText('/metrics', { skipAuth: true });
  }
}
