defmodule Mix.Tasks.Evil.Retention.Purge do
  @moduledoc """
  Hard-delete aged terminal process-instance trees per `TDE_RETENTION_*_DAYS`.

  Only root process instances are selected. A root is skipped when any
  descendant is still `running` or `suspended`. Unset days knobs mean
  that state is never selected. When no days knob is set, this task is
  a no-op.

  Schedule via cron or systemd. The engine does not run a RetentionRunner
  GenServer.

  ## Usage

      mix evil.retention.purge
      mix evil.retention.purge --dry-run

  Also invoked from a release via
  `EvilEngine.Persistence.Release.purge_retention/0`.
  """

  use Mix.Task

  alias EvilEngine.Persistence.ProcessInstancePurge

  @shortdoc "Hard-delete aged terminal process-instance trees"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {parsed, _remaining, _invalid} =
      OptionParser.parse(args, strict: [dry_run: :boolean], aliases: [n: :dry_run])

    dry_run = Keyword.get(parsed, :dry_run, false)
    retention_config = Application.get_env(:peripheral_persistence, :retention, [])

    if ProcessInstancePurge.any_days_policy?(retention_config) do
      case ProcessInstancePurge.purge_eligible_trees(dry_run: dry_run) do
        {:ok, result} ->
          Mix.shell().info(
            "Retention purge#{dry_run_label(result.dry_run)}: " <>
              "purged_root_count=#{result.purged_root_count} " <>
              "skipped_root_count=#{result.skipped_root_count}"
          )

        {:error, reason} ->
          Mix.raise("Retention purge failed: #{inspect(reason)}")
      end
    else
      Mix.shell().info("No TDE_RETENTION_*_DAYS configured; nothing to purge")
    end
  end

  defp dry_run_label(true), do: " (dry-run)"
  defp dry_run_label(false), do: ""
end
