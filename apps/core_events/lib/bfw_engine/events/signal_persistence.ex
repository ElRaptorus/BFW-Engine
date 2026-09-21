defmodule BfwEngine.Events.SignalPersistence do
  @moduledoc """
  Behaviour for signal audit and pending-signal persistence.

  `core_events` defines this contract; `peripheral_persistence`
  provides the implementation. The implementation module is injected
  via `config :core_events, :signal_persistence_adapter`.

  When no adapter is configured (e.g. in unit tests), all operations
  are no-ops that succeed silently.
  """

  @type pending_row :: %{
          id: String.t(),
          signal_id: String.t(),
          signal_name: String.t(),
          published_at: DateTime.t(),
          expires_at: DateTime.t(),
          state: String.t()
        }

  @callback insert_signal(map()) :: {:ok, String.t()} | {:error, term()}
  @callback insert_pending_signal(map()) :: {:ok, String.t()} | {:error, term()}
  @callback find_pending_signals(String.t()) :: {:ok, [pending_row()]}
  @callback mark_pending_delivered(String.t()) :: :ok | {:error, term()}
  @callback cancel_pending_for_signal_name(String.t()) :: {:ok, non_neg_integer()}
  @callback expire_pending_signals() :: {:ok, non_neg_integer()}
  @callback append_signal_delivery(String.t(), map()) :: :ok | {:error, term()}
  @callback update_started_process_instance_ids(String.t(), [String.t()]) ::
              :ok | {:error, term()}

  @doc "Returns the configured adapter module, or `nil` if none."
  @spec adapter() :: module() | nil
  def adapter do
    Application.get_env(:core_events, :signal_persistence_adapter)
  end
end
