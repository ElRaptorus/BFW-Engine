defmodule EvilEngine.Persistence.TimerStartScheduleAdapter do
  @moduledoc """
  Postgres implementation of `EvilEngine.Timers.Persistence`.

  Persists cycle Timer Start schedules so they survive engine restart.
  Production config (`config/config.exs`) points `:core_timers,
  :persistence_module` at this module. Tests in `core_timers` keep
  `EvilEngine.Timers.Persistence.NoOp`; umbrella integration tests
  switch to this adapter via `ExecutionCase`.
  """

  @behaviour EvilEngine.Timers.Persistence

  alias EvilEngine.Execution.PersistenceRetry
  alias EvilEngine.Persistence.Resources.TimerStartSchedule

  require Ash.Query

  @retry_opts [max_attempts: 3]

  @impl true
  def create_schedule(attrs) do
    params = schedule_create_params(attrs)

    PersistenceRetry.with_retry(
      fn ->
        case Ash.create(TimerStartSchedule, params, authorize?: false) do
          {:ok, record} -> {:ok, to_schedule_record(record)}
          {:error, reason} -> {:error, reason}
        end
      end,
      "create_schedule",
      @retry_opts
    )
  end

  @impl true
  def update_schedule(id, changes) do
    PersistenceRetry.with_retry(
      fn -> apply_schedule_update(id, changes) end,
      "update_schedule",
      @retry_opts
    )
  end

  @impl true
  def delete_schedules_for_version(process_version_id) do
    PersistenceRetry.with_retry(
      fn ->
        result =
          TimerStartSchedule
          |> Ash.Query.filter(process_version_id == ^process_version_id)
          |> Ash.bulk_destroy(:destroy, %{}, authorize?: false, return_errors?: true)

        case result do
          %Ash.BulkResult{status: :success} -> :ok
          %Ash.BulkResult{status: :error, errors: errors} -> {:error, errors}
          other -> {:error, other}
        end
      end,
      "delete_schedules_for_version",
      @retry_opts
    )
  end

  @impl true
  def list_armed_schedules do
    PersistenceRetry.with_retry(
      fn ->
        query =
          TimerStartSchedule
          |> Ash.Query.filter(enabled == true and not is_nil(next_fire_at))
          |> Ash.Query.sort(next_fire_at: :asc)

        case Ash.read(query, authorize?: false) do
          {:ok, records} -> {:ok, Enum.map(records, &to_schedule_record/1)}
          {:error, reason} -> {:error, reason}
        end
      end,
      "list_armed_schedules",
      @retry_opts
    )
  end

  @impl true
  def list_all_schedules(opts \\ []) do
    PersistenceRetry.with_retry(
      fn ->
        query = apply_list_filters(TimerStartSchedule, opts)

        case Ash.read(query, authorize?: false) do
          {:ok, records} -> {:ok, Enum.map(records, &to_schedule_record/1)}
          {:error, reason} -> {:error, reason}
        end
      end,
      "list_all_schedules",
      @retry_opts
    )
  end

  @impl true
  def get_schedule(id) do
    PersistenceRetry.with_retry(
      fn ->
        case fetch_schedule(id) do
          {:ok, record} -> {:ok, to_schedule_record(record)}
          {:error, :not_found} -> {:error, :not_found}
          {:error, reason} -> {:error, reason}
        end
      end,
      "get_schedule",
      @retry_opts
    )
  end

  defp apply_schedule_update(id, changes) do
    with {:ok, record} <- fetch_schedule(id) do
      persist_schedule_update(record, Map.take(changes, update_keys()))
    end
  end

  defp persist_schedule_update(record, params) do
    case Ash.update(record, params, authorize?: false) do
      {:ok, updated} -> {:ok, to_schedule_record(updated)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_schedule(id) do
    case Ash.get(TimerStartSchedule, id, authorize?: false) do
      {:ok, record} -> {:ok, record}
      {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{} | _]}} -> {:error, :not_found}
      {:error, %Ash.Error.Query.NotFound{}} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp apply_list_filters(queryable, opts) do
    Enum.reduce(opts, queryable, fn
      {:process_version_id, version_id}, query ->
        Ash.Query.filter(query, process_version_id == ^version_id)

      _other, query ->
        query
    end)
  end

  defp schedule_create_params(attrs) do
    attrs
    |> Map.take([
      :id,
      :process_version_id,
      :process_model_id,
      :flow_node_id,
      :kind,
      :iso_spec,
      :enabled,
      :next_fire_at,
      :last_triggered_at,
      :cycle_total,
      :cycle_remaining,
      :scheduler_ref
    ])
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp update_keys do
    [
      :enabled,
      :next_fire_at,
      :last_triggered_at,
      :cycle_total,
      :cycle_remaining,
      :scheduler_ref
    ]
  end

  defp to_schedule_record(record) do
    %{
      id: to_string(record.id),
      process_version_id: to_string(record.process_version_id),
      process_model_id: record.process_model_id,
      flow_node_id: record.flow_node_id,
      kind: record.kind,
      iso_spec: record.iso_spec,
      enabled: record.enabled,
      next_fire_at: record.next_fire_at,
      last_triggered_at: record.last_triggered_at,
      cycle_total: record.cycle_total,
      cycle_remaining: record.cycle_remaining,
      scheduler_ref: record.scheduler_ref
    }
  end
end
