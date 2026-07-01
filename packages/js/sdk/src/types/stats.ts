/** Engine load level as reported by the load-shedding subsystem. */
export type LoadLevel = 'normal' | 'elevated' | 'critical';

/** Per-plugin stats entry as returned in the `/stats` response. */
export interface PluginStatsEntry {
  /** Plugin name. */
  name: string;
  /** Plugin version. */
  version: string;
  /** Registered capability types. */
  capabilities: string[];
  /** Plugin-specific metrics. */
  metrics: Record<string, unknown>;
}

/** Response body for `GET /stats` — full engine state snapshot. */
export interface StatsResponse {
  engine: {
    id: string;
    name: string;
    version: string;
    startedAt: string;
    uptimeSeconds: number;
    load: LoadLevel;
  };
  processInstances: {
    running: number;
    finished: number;
    fatal: number;
    aborted: number;
    error: number;
    escalated: number;
    compensated: number;
  };
  flowNodeInstances: {
    active: number;
    finished: number;
    fatal: number;
    aborted: number;
    interrupted: number;
    byType: Record<string, number>;
  };
  userTasksPending: { count: number; byAssigneeRole: Record<string, number> };
  asyncFlowNodes: { waiting: number; byPlugin: Record<string, number> };
  timers: { armed: number; fireInNextMinute: number };
  plugins: PluginStatsEntry[];
  listeners: {
    eventSinksCount: number;
    eventSinksByName: Record<string, 'on' | 'off'>;
    monitoringPanelsCount: number;
  };
}
