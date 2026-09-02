defmodule EvilEngine.Persistence.SignalPersistenceAdapter do
  @moduledoc """
  Implementation of `EvilEngine.Events.SignalPersistence` backed by
  the `Signal` and `PendingSignal` Ash resources.
  """

  @behaviour EvilEngine.Events.SignalPersistence

  alias EvilEngine.Execution.PersistenceRetry
  alias EvilEngine.Persistence.Resources.PendingSignal
  alias EvilEngine.Persistence.Resources.Signal

  require Ash.Query
  require Logger

  @retry_opts [max_attempts: 3]

  @impl true
  def insert_signal(params) do
    PersistenceRetry.with_retry(
      fn ->
        case Ash.create(Signal, params, authorize?: false) do
          {:ok, record} -> {:ok, record.id}
          {:error, reason} -> {:error, reason}
        end
      end,
      "insert_signal",
      @retry_opts
    )
  end

  @impl true
  def insert_pending_signal(params) do
    PersistenceRetry.with_retry(
      fn ->
        case Ash.create(PendingSignal, params, authorize?: false) do
          {:ok, record} -> {:ok, record.id}
          {:error, reason} -> {:error, reason}
        end
      end,
      "insert_pending_signal",
      @retry_opts
    )
  end

  @impl true
  def find_pending_signals(signal_name) do
    PersistenceRetry.with_retry(
      fn -> do_find_pending_signals(signal_name) end,
      "find_pending_signals",
      @retry_opts
    )
  end

  defp do_find_pending_signals(signal_name) do
    now = DateTime.utc_now()

    query =
      PendingSignal
      |> Ash.Query.filter(
        state == "pending" and signal_name == ^signal_name and expires_at > ^now
      )
      |> Ash.Query.sort(published_at: :asc)
      |> Ash.Query.limit(1)

    case Ash.read(query, authorize?: false) do
      {:ok, records} ->
        rows =
          Enum.map(records, fn record ->
            %{
              id: record.id,
              signal_id: record.signal_id,
              signal_name: record.signal_name,
              published_at: record.published_at,
              expires_at: record.expires_at,
              state: record.state
            }
          end)

        {:ok, rows}

      {:error, reason} ->
        Logger.warning(
          "SignalPersistenceAdapter: find_pending_signals failed: #{inspect(reason)}"
        )

        {:ok, []}
    end
  end

  @impl true
  def mark_pending_delivered(pending_signal_id) do
    PersistenceRetry.with_retry(
      fn -> do_mark_pending_delivered(pending_signal_id) end,
      "mark_pending_delivered",
      @retry_opts
    )
  end

  defp do_mark_pending_delivered(pending_signal_id) do
    case Ash.get(PendingSignal, pending_signal_id, authorize?: false) do
      {:ok, record} ->
        transition_pending_signal(record, :mark_delivered)

      {:error, reason} ->
        if not_found_error?(reason) do
          {:error, {:already_claimed, reason}}
        else
          {:error, reason}
        end
    end
  end

  @impl true
  def cancel_pending_for_signal_name(signal_name) do
    PersistenceRetry.with_retry(
      fn -> do_cancel_pending_for_signal_name(signal_name) end,
      "cancel_pending_for_signal_name",
      @retry_opts
    )
  end

  defp do_cancel_pending_for_signal_name(signal_name) do
    query =
      PendingSignal
      |> Ash.Query.filter(state == "pending" and signal_name == ^signal_name)
      |> Ash.Query.limit(500)

    case Ash.read(query, authorize?: false) do
      {:ok, records} ->
        cancelled_count =
          Enum.count(records, fn record ->
            match?(:ok, transition_pending_signal(record, :mark_expired))
          end)

        {:ok, cancelled_count}

      {:error, reason} ->
        Logger.warning(
          "SignalPersistenceAdapter: cancel_pending_for_signal_name failed: #{inspect(reason)}"
        )

        {:ok, 0}
    end
  end

  @impl true
  def expire_pending_signals do
    PersistenceRetry.with_retry(
      fn -> do_expire_pending_signals() end,
      "expire_pending_signals",
      @retry_opts
    )
  end

  defp do_expire_pending_signals do
    now = DateTime.utc_now()

    query =
      PendingSignal
      |> Ash.Query.filter(state == "pending")
      |> Ash.Query.limit(500)

    case Ash.read(query, authorize?: false) do
      {:ok, records} ->
        records
        |> Enum.filter(fn record -> DateTime.compare(record.expires_at, now) in [:lt, :eq] end)
        |> expire_records()

      {:error, reason} ->
        Logger.warning(
          "SignalPersistenceAdapter: expire_pending_signals failed: #{inspect(reason)}"
        )

        {:ok, 0}
    end
  end

  defp expire_records(expired_records) do
    expired_count =
      Enum.count(expired_records, fn record ->
        match?(:ok, transition_pending_signal(record, :mark_expired))
      end)

    {:ok, expired_count}
  end

  defp keep_pending_signals_after_transition? do
    :peripheral_persistence
    |> Application.get_env(:retention, [])
    |> Keyword.get(:pending_signals_keep_after_transition, true)
  end

  defp transition_pending_signal(record, keep_action) do
    if keep_pending_signals_after_transition?() do
      case Ash.update(record, %{}, action: keep_action, authorize?: false) do
        {:ok, _} -> :ok
        {:error, %Ash.Error.Invalid{} = error} -> {:error, {:already_claimed, error}}
        {:error, reason} -> {:error, reason}
      end
    else
      case Ash.destroy(record, action: :destroy_if_pending, authorize?: false) do
        :ok -> :ok
        {:ok, _} -> :ok
        {:error, %Ash.Error.Invalid{} = error} -> {:error, {:already_claimed, error}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp not_found_error?(%Ash.Error.Invalid{errors: errors}) do
    Enum.any?(errors, &match?(%Ash.Error.Query.NotFound{}, &1))
  end

  defp not_found_error?(_reason), do: false

  @impl true
  def update_started_process_instance_ids(signal_id, started_ids) do
    PersistenceRetry.with_retry(
      fn -> do_update_started_process_instance_ids(signal_id, started_ids) end,
      "update_started_process_instance_ids",
      @retry_opts
    )
  end

  defp do_update_started_process_instance_ids(signal_id, started_ids) do
    case Ash.get(Signal, signal_id, authorize?: false) do
      {:ok, record} ->
        case Ash.update(
               record,
               %{started_process_instance_ids: started_ids},
               action: :update_started_process_instance_ids,
               authorize?: false
             ) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def append_signal_delivery(signal_id, delivery_entry) do
    PersistenceRetry.with_retry(
      fn -> do_append_signal_delivery(signal_id, delivery_entry) end,
      "append_signal_delivery",
      @retry_opts
    )
  end

  defp do_append_signal_delivery(signal_id, delivery_entry) do
    case Ash.get(Signal, signal_id, authorize?: false) do
      {:ok, record} ->
        updated_deliveries = (record.deliveries || []) ++ [delivery_entry]

        case Ash.update(record, %{deliveries: updated_deliveries},
               action: :append_delivery,
               authorize?: false
             ) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
