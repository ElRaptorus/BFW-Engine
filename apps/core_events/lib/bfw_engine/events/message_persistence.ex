defmodule BfwEngine.Events.MessagePersistence do
  @moduledoc """
  Behaviour for message audit and pending-message persistence.

  `core_events` defines this contract; `peripheral_persistence`
  provides the implementation. The implementation module is injected
  via `config :core_events, :message_persistence_adapter`.

  When no adapter is configured (e.g. in unit tests), all operations
  are no-ops that succeed silently.
  """

  @type pending_row :: %{
          id: String.t(),
          message_id: String.t(),
          message_name: String.t(),
          correlation_value: String.t() | nil,
          payload: map(),
          published_at: DateTime.t(),
          expires_at: DateTime.t(),
          state: String.t()
        }

  @callback insert_message(map()) :: {:ok, String.t()} | {:error, term()}
  @callback insert_pending_message(map()) :: {:ok, String.t()} | {:error, term()}
  @callback find_pending_messages(String.t(), String.t() | nil) :: {:ok, [pending_row()]}
  @callback mark_pending_delivered(String.t()) :: :ok | {:error, term()}
  @callback cancel_pending_for_message(String.t(), String.t() | nil) :: {:ok, non_neg_integer()}
  @callback expire_pending_messages() :: {:ok, non_neg_integer()}
  @callback append_message_correlation(String.t(), map()) :: :ok | {:error, term()}
  @callback update_started_process_instance_ids(String.t(), [String.t()]) ::
              :ok | {:error, term()}

  @doc "Returns the configured adapter module, or `nil` if none."
  @spec adapter() :: module() | nil
  def adapter do
    Application.get_env(:core_events, :message_persistence_adapter)
  end
end
