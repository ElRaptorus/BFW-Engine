defmodule BfwEngine.Api.AshWrite do
  @moduledoc false

  # Called by BfwEngine.Api.Processes and BfwEngine.Api.Decisions.
  # Ash cannot deliver notifiers from inside `Repo.transaction/1`. Collect
  # notifications while a stash is active and flush after commit (P88).
  def ash_create(changeset) do
    case Ash.create(changeset, authorize?: false, return_notifications?: true) do
      {:ok, record, notifications} ->
        collect_ash_notifications(notifications)
        {:ok, record}

      {:ok, record} ->
        {:ok, record}

      error ->
        error
    end
  end

  def stash_ash_notifications do
    Process.put(:bfw_engine_ash_notifications, [])
    :ok
  end

  defp collect_ash_notifications(notifications) do
    wrapped = List.wrap(notifications)

    case Process.get(:bfw_engine_ash_notifications) do
      nil ->
        _notified = Ash.Notifier.notify(wrapped)
        :ok

      accumulated ->
        Process.put(:bfw_engine_ash_notifications, accumulated ++ wrapped)
        :ok
    end
  end

  def flush_ash_notifications({:ok, _result}) do
    notifications = Process.delete(:bfw_engine_ash_notifications) || []
    _notified = Ash.Notifier.notify(notifications)
    :ok
  end

  def flush_ash_notifications(_tx_result) do
    Process.delete(:bfw_engine_ash_notifications)
    :ok
  end
end
