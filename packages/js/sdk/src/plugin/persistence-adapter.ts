/** Handler interface for persistence adapter plugins. */
export interface PersistenceAdapterHandler {
  init(options: Record<string, unknown>): Promise<void>;
  persist(changeset: Record<string, unknown>, state: Record<string, unknown>): Promise<void>;
}
