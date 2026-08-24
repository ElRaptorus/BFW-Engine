/**
 * Handler interface for data store adapter plugins.
 *
 * Not implemented in v1. `registerDataStoreAdapter` is accepted and unused at
 * runtime — BPMN DataStores remain a parser no-op.
 */
export interface DataStoreAdapterHandler {
  storeId(): string;
  read(key: string, options?: Record<string, unknown>): Promise<unknown>;
  write(key: string, value: unknown, options?: Record<string, unknown>): Promise<void>;
}
