defmodule BfwEngine.Persistence do
  @moduledoc """
  Public namespace for the engine's persistence layer.

  Ships:

    * `BfwEngine.Persistence.Repo` — `AshPostgres.Repo`
    * `BfwEngine.Persistence.ReadRepo` — read pool
    * `BfwEngine.Persistence.Api` — Ash domain
    * `BfwEngine.Persistence.Application` — supervision root (Repo + ReadRepo)
    * `BfwEngine.Persistence.ProcessInstancePurge` — opt-in Mix/eval hard-delete
      of aged terminal process-instance trees (`mix bfw.retention.purge`)
    * `BfwEngine.Persistence.Release` — prod-time migrate /
      ensure_partitions / purge_retention entrypoints invoked from
      `bin/bfw_engine eval`

  Ash resources (`Processes`, `ProcessVersions`, `ProcessInstances`,
  `FlowNodeInstances`, …) live under `BfwEngine.Persistence.Resources`.
  """
end
