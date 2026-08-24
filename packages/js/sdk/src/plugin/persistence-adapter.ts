/**
 * Handler interface for persistence adapter plugins.
 *
 * Not implemented in v1. `registerPersistenceAdapter` is accepted and unused
 * at runtime — it does not replace `EvilEngine.Execution.Persistence` or
 * AshPostgres.
 */
export interface PersistenceAdapterHandler {
  init(options: Record<string, unknown>): Promise<void>;
  persist(changeset: Record<string, unknown>, state: Record<string, unknown>): Promise<void>;
}
