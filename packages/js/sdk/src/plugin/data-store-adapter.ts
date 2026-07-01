/** Handler interface for data store adapter plugins. */
export interface DataStoreAdapterHandler {
  storeId(): string;
  read(key: string, options?: Record<string, unknown>): Promise<unknown>;
  write(key: string, value: unknown, options?: Record<string, unknown>): Promise<void>;
}
