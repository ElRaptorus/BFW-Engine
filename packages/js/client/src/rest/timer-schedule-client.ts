import type { TimerSchedule } from '@elraptorus/daemonengine_sdk';

import type { HttpTransport } from '../http/transport.js';

export interface TimerScheduleListFilters {
  processVersionId?: string;
  enabled?: boolean;
}

interface TimerScheduleEnvelope {
  data: TimerSchedule;
}

interface TimerScheduleListEnvelope {
  data: TimerSchedule[];
}

/**
 * REST sub-client for `GET/PUT /timer-schedules/*` — Timer Start Event
 * cycle schedule listing and enable/disable.
 */
export class TimerScheduleClient {
  constructor(private readonly transport: HttpTransport) {}

  /** List timer schedules. Optional filters: `processVersionId`, `enabled`. */
  async list(filters?: TimerScheduleListFilters): Promise<TimerSchedule[]> {
    const params = new URLSearchParams();
    if (filters?.processVersionId) {
      params.set('processVersionId', filters.processVersionId);
    }
    if (filters?.enabled !== undefined) {
      params.set('enabled', String(filters.enabled));
    }
    const query = params.toString();
    const path = query ? `/timer-schedules?${query}` : '/timer-schedules';
    const body = await this.transport.get<TimerScheduleListEnvelope>(path);
    return body.data;
  }

  /** Get a single timer schedule by id. */
  async get(scheduleId: string): Promise<TimerSchedule> {
    const encodedId = encodeURIComponent(scheduleId);
    const body = await this.transport.get<TimerScheduleEnvelope>(`/timer-schedules/${encodedId}`);
    return body.data;
  }

  /** Re-enable a disabled cycle timer schedule. */
  async enable(scheduleId: string): Promise<void> {
    const encodedId = encodeURIComponent(scheduleId);
    await this.transport.put(`/timer-schedules/${encodedId}/enable`);
  }

  /** Disable an enabled cycle timer schedule. */
  async disable(scheduleId: string): Promise<void> {
    const encodedId = encodeURIComponent(scheduleId);
    await this.transport.put(`/timer-schedules/${encodedId}/disable`);
  }
}
