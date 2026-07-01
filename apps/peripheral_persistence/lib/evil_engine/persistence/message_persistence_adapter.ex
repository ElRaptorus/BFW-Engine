defmodule EvilEngine.Persistence.MessagePersistenceAdapter do
  @moduledoc """
  Implementation of `EvilEngine.Events.MessagePersistence` backed by
  the `Message` and `PendingMessage` Ash resources.
  """

  @behaviour EvilEngine.Events.MessagePersistence

  alias EvilEngine.Execution.PersistenceRetry
  alias EvilEngine.Persistence.Resources.Message
  alias EvilEngine.Persistence.Resources.PendingMessage

  require Ash.Query
  require Logger

  @retry_opts [max_attempts: 3]

  @impl true
  def insert_message(params) do
    PersistenceRetry.with_retry(
      fn ->
        case Ash.create(Message, params, authorize?: false) do
          {:ok, record} -> {:ok, record.id}
          {:error, reason} -> {:error, reason}
        end
      end,
      "insert_message",
      @retry_opts
    )
  end

  @impl true
  def insert_pending_message(params) do
    PersistenceRetry.with_retry(
      fn ->
        case Ash.create(PendingMessage, params, authorize?: false) do
          {:ok, record} -> {:ok, record.id}
          {:error, reason} -> {:error, reason}
        end
      end,
      "insert_pending_message",
      @retry_opts
    )
  end

  @impl true
  def find_pending_messages(message_name, correlation_value) do
    PersistenceRetry.with_retry(
      fn -> do_find_pending_messages(message_name, correlation_value) end,
      "find_pending_messages",
      @retry_opts
    )
  end

  defp do_find_pending_messages(message_name, correlation_value) do
    now = DateTime.utc_now()

    base_query =
      PendingMessage
      |> Ash.Query.filter(
        state == "pending" and message_name == ^message_name and expires_at > ^now
      )
      |> Ash.Query.sort(published_at: :asc)
      |> Ash.Query.limit(1)

    query =
      if correlation_value do
        Ash.Query.filter(base_query, correlation_value == ^correlation_value)
      else
        Ash.Query.filter(base_query, is_nil(correlation_value))
      end

    case Ash.read(query, authorize?: false) do
      {:ok, records} ->
        rows =
          Enum.map(records, fn record ->
            %{
              id: record.id,
              message_id: record.message_id,
              message_name: record.message_name,
              correlation_value: record.correlation_value,
              payload: record.payload,
              published_at: record.published_at,
              expires_at: record.expires_at,
              state: record.state
            }
          end)

        {:ok, rows}

      {:error, reason} ->
        Logger.warning(
          "MessagePersistenceAdapter: find_pending_messages failed: #{inspect(reason)}"
        )

        {:ok, []}
    end
  end

  @impl true
  def mark_pending_delivered(pending_message_id) do
    PersistenceRetry.with_retry(
      fn -> do_mark_pending_delivered(pending_message_id) end,
      "mark_pending_delivered",
      @retry_opts
    )
  end

  defp do_mark_pending_delivered(pending_message_id) do
    case Ash.get(PendingMessage, pending_message_id, authorize?: false) do
      {:ok, record} ->
        case Ash.update(record, %{}, action: :mark_delivered, authorize?: false) do
          {:ok, _} -> :ok
          {:error, %Ash.Error.Invalid{} = error} -> {:error, {:already_claimed, error}}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def cancel_pending_for_message(message_name, correlation_value) do
    PersistenceRetry.with_retry(
      fn -> do_cancel_pending_for_message(message_name, correlation_value) end,
      "cancel_pending_for_message",
      @retry_opts
    )
  end

  defp do_cancel_pending_for_message(message_name, correlation_value) do
    base_query =
      PendingMessage
      |> Ash.Query.filter(state == "pending" and message_name == ^message_name)
      |> Ash.Query.limit(500)

    query =
      if correlation_value do
        Ash.Query.filter(base_query, correlation_value == ^correlation_value)
      else
        Ash.Query.filter(base_query, is_nil(correlation_value))
      end

    case Ash.read(query, authorize?: false) do
      {:ok, records} ->
        cancelled_count =
          Enum.count(records, fn record ->
            match?({:ok, _}, Ash.update(record, %{}, action: :mark_expired, authorize?: false))
          end)

        {:ok, cancelled_count}

      {:error, reason} ->
        Logger.warning(
          "MessagePersistenceAdapter: cancel_pending_for_message failed: #{inspect(reason)}"
        )

        {:ok, 0}
    end
  end

  @impl true
  def expire_pending_messages do
    PersistenceRetry.with_retry(
      fn -> do_expire_pending_messages() end,
      "expire_pending_messages",
      @retry_opts
    )
  end

  defp do_expire_pending_messages do
    now = DateTime.utc_now()

    query =
      PendingMessage
      |> Ash.Query.filter(state == "pending")
      |> Ash.Query.limit(500)

    case Ash.read(query, authorize?: false) do
      {:ok, records} ->
        records
        |> Enum.filter(fn record -> DateTime.compare(record.expires_at, now) in [:lt, :eq] end)
        |> expire_records()

      {:error, reason} ->
        Logger.warning(
          "MessagePersistenceAdapter: expire_pending_messages failed: #{inspect(reason)}"
        )

        {:ok, 0}
    end
  end

  defp expire_records(expired_records) do
    expired_count =
      Enum.count(expired_records, fn record ->
        match?({:ok, _}, Ash.update(record, %{}, action: :mark_expired, authorize?: false))
      end)

    {:ok, expired_count}
  end

  @impl true
  def update_started_process_instance_ids(message_id, started_ids) do
    PersistenceRetry.with_retry(
      fn -> do_update_started_process_instance_ids(message_id, started_ids) end,
      "update_started_process_instance_ids",
      @retry_opts
    )
  end

  defp do_update_started_process_instance_ids(message_id, started_ids) do
    case Ash.get(Message, message_id, authorize?: false) do
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
  def append_message_correlation(message_id, correlation_entry) do
    PersistenceRetry.with_retry(
      fn -> do_append_message_correlation(message_id, correlation_entry) end,
      "append_message_correlation",
      @retry_opts
    )
  end

  defp do_append_message_correlation(message_id, correlation_entry) do
    case Ash.get(Message, message_id, authorize?: false) do
      {:ok, record} ->
        updated_correlations = (record.correlations || []) ++ [correlation_entry]

        case Ash.update(record, %{correlations: updated_correlations},
               action: :append_correlation,
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
