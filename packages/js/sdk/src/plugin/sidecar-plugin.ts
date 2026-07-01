/**
 * Forward-looking gRPC sidecar plugin contract (BPMN Phase 5).
 * Sidecar binaries connect to the engine bridge, register capabilities,
 * and subscribe to engine events over the wire.
 */

export interface SidecarEventFilter {
  eventTypes: string[];
}

export interface SidecarPlugin {
  readonly name: string;
  connect(): Promise<void>;
  register(): Promise<void>;
  onEvent(filter: SidecarEventFilter, handler: (event: Record<string, unknown>) => void): void;
  disconnect(): Promise<void>;
}
