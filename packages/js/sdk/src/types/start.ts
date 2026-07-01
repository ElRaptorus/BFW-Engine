/** Optional parameters for starting a process instance. */
export interface StartRequest {
  /** BPMN ID of the start event to use. Required when the process has multiple start events. */
  startEventId?: string;
  /** Initial payload passed to the process instance's first token. */
  payload?: Record<string, unknown>;
  /** Immutable context variables accessible as `context.*` in FEEL expressions. Independent from the token payload. When omitted, the engine falls back to the payload for backward compatibility. */
  context?: Record<string, unknown>;
  /** User-defined business key for grouping related process instances. */
  businessKey?: string;
}

/** Response body for `POST /processes/:id/start`. */
export interface StartResult {
  /** Engine-assigned UUID of the newly created process instance. */
  processInstanceId: string;
  /** BPMN process ID. */
  processModelId: string;
  /** The version string the instance was started on. */
  version: string;
  /** The instance state immediately after start (always "running"). */
  state: 'running';
}
