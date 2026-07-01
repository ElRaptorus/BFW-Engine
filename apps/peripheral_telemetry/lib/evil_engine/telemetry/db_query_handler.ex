defmodule EvilEngine.Telemetry.DbQueryHandler do
  @moduledoc """
  Telemetry handler for Ecto query events.

  Attaches to each Repo's `[:repo, :query]` event and re-emits
  standardized `[:evil_engine, :db, :query, :*]` events with
  millisecond-precision measurements. Also logs a warning when
  checkout wait (`queue_time`) exceeds a configurable threshold,
  which indicates pool pressure.

  Supports multiple repos (write `Repo` + read `ReadRepo`). The
  `repo` tag on emitted events allows per-pool dashboarding.
  """

  require Logger

  @handler_id "evil-engine-db-query-handler"

  @queue_time_warning_ms Application.compile_env(
                           :peripheral_telemetry,
                           :db_queue_time_warning_ms,
                           500
                         )

  @doc """
  Attaches this handler to Ecto query telemetry events for all
  known repos. Call once at application startup.
  """
  @spec attach() :: :ok
  def attach do
    repos = known_repos()

    events =
      Enum.map(repos, fn {_label, repo_module} ->
        telemetry_prefix(repo_module) ++ [:query]
      end)

    case :telemetry.attach_many(
           @handler_id,
           events,
           &__MODULE__.handle_event/4,
           %{repos: Map.new(repos, fn {label, mod} -> {mod, label} end)}
         ) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  end

  @doc false
  def handle_event(_event_name, measurements, metadata, config) do
    repo_module = metadata[:repo]
    repo_label = Map.get(config.repos, repo_module, :unknown)

    queue_time_ms = native_to_ms(measurements[:queue_time])
    query_time_ms = native_to_ms(measurements[:query_time])
    decode_time_ms = native_to_ms(measurements[:decode_time])
    total_time_ms = native_to_ms(measurements[:total_time])

    source = metadata[:source] || "unknown"

    :telemetry.execute(
      [:evil_engine, :db, :query],
      %{
        queue_time_ms: queue_time_ms,
        query_time_ms: query_time_ms,
        decode_time_ms: decode_time_ms,
        total_time_ms: total_time_ms
      },
      %{repo: repo_label, source: source}
    )

    if queue_time_ms != nil and queue_time_ms > warning_threshold_ms() do
      Logger.warning(
        "DB pool pressure: checkout waited #{round(queue_time_ms)}ms " <>
          "(threshold: #{warning_threshold_ms()}ms, repo: #{repo_label}, " <>
          "source: #{source})"
      )
    end
  end

  defp known_repos do
    repos = [{:write, EvilEngine.Persistence.Repo}]

    if Code.ensure_loaded?(EvilEngine.Persistence.ReadRepo) do
      repos ++ [{:read, EvilEngine.Persistence.ReadRepo}]
    else
      repos
    end
  end

  defp telemetry_prefix(repo_module) do
    repo_module
    |> Module.split()
    |> Enum.map(&(&1 |> Macro.underscore() |> String.to_atom()))
  end

  defp native_to_ms(nil), do: nil

  defp native_to_ms(native) do
    System.convert_time_unit(native, :native, :millisecond) / 1
  end

  defp warning_threshold_ms do
    Application.get_env(:peripheral_telemetry, :db_queue_time_warning_ms, @queue_time_warning_ms)
  end
end
