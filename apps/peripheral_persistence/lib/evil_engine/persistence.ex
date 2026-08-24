defmodule EvilEngine.Persistence do
  @moduledoc """
  Public namespace for the engine's persistence layer.

  Ships:

    * `EvilEngine.Persistence.Repo` — `AshPostgres.Repo`
    * `EvilEngine.Persistence.ReadRepo` — read pool
    * `EvilEngine.Persistence.Api` — Ash domain
    * `EvilEngine.Persistence.Application` — supervision root (Repo + ReadRepo).
      `RetentionRunner` is Phase 7 and does **not** ship today.
    * `EvilEngine.Persistence.Release` — prod-time migrate /
      ensure_partitions entrypoints invoked from `bin/evil_engine eval`

  Ash resources (`Processes`, `ProcessVersions`, `ProcessInstances`,
  `FlowNodeInstances`, …) live under `EvilEngine.Persistence.Resources`.
  """
end
