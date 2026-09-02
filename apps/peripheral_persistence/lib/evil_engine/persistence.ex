defmodule EvilEngine.Persistence do
  @moduledoc """
  Public namespace for the engine's persistence layer.

  Ships:

    * `EvilEngine.Persistence.Repo` — `AshPostgres.Repo`
    * `EvilEngine.Persistence.ReadRepo` — read pool
    * `EvilEngine.Persistence.Api` — Ash domain
    * `EvilEngine.Persistence.Application` — supervision root (Repo + ReadRepo)
    * `EvilEngine.Persistence.ProcessInstancePurge` — opt-in Mix/eval hard-delete
      of aged terminal process-instance trees (`mix evil.retention.purge`)
    * `EvilEngine.Persistence.Release` — prod-time migrate /
      ensure_partitions / purge_retention entrypoints invoked from
      `bin/evil_engine eval`

  Ash resources (`Processes`, `ProcessVersions`, `ProcessInstances`,
  `FlowNodeInstances`, …) live under `EvilEngine.Persistence.Resources`.
  """
end
