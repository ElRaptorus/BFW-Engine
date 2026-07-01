defmodule EvilEngine.Persistence do
  @moduledoc """
  Public namespace for the engine's persistence layer.

  Phase 0 ships:

    * `EvilEngine.Persistence.Repo` — `AshPostgres.Repo`
    * `EvilEngine.Persistence.Api`  — empty Ash domain
    * <code>EvilEngine.Persistence.Application</code> — supervision root (Repo,
      later the `RetentionRunner` GenServer)
    * `EvilEngine.Persistence.Release` — prod-time migrate/
      ensure_partitions entrypoints invoked from `bin/evil_engine eval`

  Phase 1 adds the first Ash resources (`Processes`, `ProcessVersions`,
  `ProcessInstances`, `FlowNodeInstances`, …).
  """
end
