defmodule Mix.Tasks.Evil.Partitions.Ensure do
  @moduledoc """
  Pre-create monthly/quarterly/half-yearly/yearly partitions for all
  partitioned audit tables.

  Reads `TDE_PARTITION_INTERVAL` (default `quarterly`) and
  `TDE_PARTITION_AHEAD_MONTHS` (default `3`) from config.

  When `TDE_PARTITION_INTERVAL=off`, this task is a no-op.

  ## Usage

      mix evil.partitions.ensure

  Also invoked at release boot via
  `EvilEngine.Persistence.Release.ensure_partitions/0`.
  """

  use Mix.Task

  alias EvilEngine.Persistence.Partitions

  @shortdoc "Pre-create time-range partitions for audit tables"

  @impl true
  def run(_args) do
    Mix.Task.run("app.start")

    {:ok, count} = Partitions.ensure_partitions()
    Mix.shell().info("Partitions ensured: #{count}")
  end
end
