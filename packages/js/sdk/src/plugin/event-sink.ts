import type { EngineEvent, EngineEventEnvelope } from '../events/engine-events.js';

/**
 * Handler for processing engine events. Per SinkWorker architecture (A-2/PF-3):
 * - Events are delivered **in-order** per sink (GenServer mailbox)
 * - Sinks are **isolated** — one sink's failure does not affect others
 * - When `handle` throws, the worker publishes a `SinkFailed` event
 *   and continues with unchanged state (no crack)
 * - Workers are restarted by the supervisor on unexpected termination
 */
export interface EventSinkHandler {
  /** Fast filter called before handle. Return false to skip an event. */
  accepts(event: EngineEvent): boolean;
  handle(event: EngineEventEnvelope): void | Promise<void>;
}

/** Options for event sink registration. */
export interface EventSinkOptions {
  /** If true, the sink receives events that other sinks have already handled. */
  receiveHandled?: boolean;
}
