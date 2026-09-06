defmodule EvilEngine.Persistence.Release do
  @moduledoc """
  Release-time entry points, invoked from the OTP release via
  `bin/evil_engine eval "EvilEngine.Persistence.Release.migrate()"`.

  Used by the Docker `ENTRYPOINT` and by operators who run the release
  outside Docker.
  """

  alias EvilEngine.Persistence.Partitions
  alias EvilEngine.Persistence.ProcessInstancePurge

  @app :peripheral_persistence

  @doc "Run every pending Ecto migration."
  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end

    :ok
  end

  @doc "Rollback the Repo to `version`."
  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
    :ok
  end

  @doc """
  Pre-create partitions for every partitioned audit table,
  `TDE_PARTITION_AHEAD_MONTHS` into the future.

  The partition interval is controlled by `TDE_PARTITION_INTERVAL`
  (monthly, quarterly, half_yearly, yearly, off). When `off`, this
  is a no-op.

  Currently covers: `process_instance_events`, `data_object_writes`,
  `messages`, `pending_messages`, `signals`, `pending_signals`.
  There is no `pending_escalations` table (escalation D1). There are no
  `escalations`, `compensations`, or `engine_timers` tables.
  `timer_start_schedules` is operational and unpartitioned.
  """
  def ensure_partitions do
    load_app()

    {:ok, _} = Application.ensure_all_started(:peripheral_persistence)

    {:ok, _count} = Partitions.ensure_partitions()
    :ok
  end

  @doc """
  Hard-delete aged terminal process-instance trees per
  `TDE_RETENTION_*_DAYS`.

  Pass `dry_run: true` to count eligible roots without deleting.

  Used from a release as
  `bin/evil_engine eval "EvilEngine.Persistence.Release.purge_retention()"`.
  """
  def purge_retention(opts \\ []) do
    load_app()

    {:ok, _} = Application.ensure_all_started(:peripheral_persistence)

    ProcessInstancePurge.purge_eligible_trees(opts)
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    case Application.load(@app) do
      :ok -> :ok
      {:error, {:already_loaded, @app}} -> :ok
    end
  end
end
