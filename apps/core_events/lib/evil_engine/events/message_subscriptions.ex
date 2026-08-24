defmodule EvilEngine.Events.MessageSubscriptions do
  @moduledoc """
  In-memory subscription registry for BPMN Message Events.

  Manages an ETS `:bag` table keyed by `{message_name, correlation_value}`
  for O(1) lookup on publish. Each entry is a `Subscription` struct
  representing a waiting catch event, boundary event, or receive task.

  ## Readiness gate

  After an engine restart, PIs resume and re-register their subscriptions.
  The registry starts in a "not ready" state; the `POST /messages/{name}/trigger`
  endpoint returns 503 until `mark_ready/0` is called by the resume pipeline
  (prevents publish-before-subscribe race per §3.5.5).

  ## Scoping

  This registry is scoped to **messages only**. Signal subscriptions are
  handled by `EvilEngine.Events.SignalSubscriptions`; escalations use a
  scope-chain walker (Phase 4), not a subscription registry.
  """

  use GenServer

  require Logger

  @table_name :evil_engine_message_subscriptions
  @process_instance_index_table :evil_engine_message_subscriptions_by_process_instance

  # -------------------------------------------------------------------
  # Subscription struct
  # -------------------------------------------------------------------

  defmodule Subscription do
    @moduledoc "A single message subscription entry stored in the ETS table."

    @type kind :: :intermediate_catch | :boundary | :receive_task | :event_subprocess_start

    @type t :: %__MODULE__{
            subscription_id: String.t(),
            process_instance_id: String.t(),
            flow_node_instance_id: String.t(),
            flow_node_id: String.t(),
            message_name: String.t(),
            expected_correlation_value: String.t() | :none,
            kind: kind(),
            registered_at: DateTime.t(),
            via_pid: pid(),
            lane_name: String.t() | nil
          }

    @enforce_keys [
      :subscription_id,
      :process_instance_id,
      :flow_node_instance_id,
      :flow_node_id,
      :message_name,
      :expected_correlation_value,
      :kind,
      :registered_at,
      :via_pid
    ]

    defstruct [
      :subscription_id,
      :process_instance_id,
      :flow_node_instance_id,
      :flow_node_id,
      :message_name,
      :expected_correlation_value,
      :kind,
      :registered_at,
      :via_pid,
      :lane_name
    ]
  end

  # -------------------------------------------------------------------
  # Public API
  # -------------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Register a message subscription.

  After inserting into ETS, drains any matching pending messages from
  the persistence layer. Returns `{:ok, subscription_id}`.
  """
  @spec register(map()) :: {:ok, String.t()}
  def register(params) do
    subscription = %Subscription{
      subscription_id: generate_id(),
      process_instance_id: params.process_instance_id,
      flow_node_instance_id: params.flow_node_instance_id,
      flow_node_id: params.flow_node_id,
      message_name: params.message_name,
      expected_correlation_value: params[:expected_correlation_value] || :none,
      kind: params.kind,
      registered_at: DateTime.utc_now(),
      via_pid: params.via_pid,
      lane_name: Map.get(params, :lane_name)
    }

    key = {subscription.message_name, subscription.expected_correlation_value}
    :ets.insert(@table_name, {key, subscription})
    :ets.insert(
      @process_instance_index_table,
      {subscription.process_instance_id, key, subscription.subscription_id}
    )

    Logger.debug(
      "MessageSubscriptions: registered #{subscription.subscription_id} " <>
        "for message=#{subscription.message_name} " <>
        "correlation=#{inspect(subscription.expected_correlation_value)} " <>
        "kind=#{subscription.kind} pi=#{subscription.process_instance_id}"
    )

    drain_pending_messages(subscription)

    {:ok, subscription.subscription_id}
  end

  @doc """
  Remove a subscription by its ID.
  """
  @spec unregister(String.t()) :: :ok
  def unregister(subscription_id) do
    @table_name
    |> :ets.tab2list()
    |> Enum.filter(fn {_key, sub} -> sub.subscription_id == subscription_id end)
    |> Enum.each(fn {key, sub} ->
      :ets.delete_object(@table_name, {key, sub})

      :ets.delete_object(
        @process_instance_index_table,
        {sub.process_instance_id, key, sub.subscription_id}
      )
    end)

    :ok
  end

  @doc """
  Bulk-remove all subscriptions for a process instance.

  Belt-and-suspenders cleanup on PI termination — individual handlers
  should already unregister, but this catches edge cases.
  """
  @spec unregister_all_for_process_instance(String.t()) :: :ok
  def unregister_all_for_process_instance(process_instance_id) do
    index_entries = :ets.lookup(@process_instance_index_table, process_instance_id)

    Enum.each(index_entries, fn {indexed_process_instance_id, key, subscription_id} ->
      delete_matching_subscription(key, subscription_id)

      :ets.delete_object(
        @process_instance_index_table,
        {indexed_process_instance_id, key, subscription_id}
      )
    end)

    unless index_entries == [] do
      Logger.debug(
        "MessageSubscriptions: bulk-removed #{Enum.count(index_entries)} subscriptions for PI #{process_instance_id}"
      )
    end

    :ok
  end

  @doc """
  Look up all subscriptions matching a message name and correlation value.

  Returns all matching `Subscription` structs (broadcast-within-key).
  """
  @spec lookup(String.t(), String.t() | :none) :: [Subscription.t()]
  def lookup(message_name, correlation_value) do
    key = {message_name, correlation_value}

    @table_name
    |> :ets.lookup(key)
    |> Enum.map(fn {_key, subscription} -> subscription end)
  end

  @doc """
  Check whether any subscriptions exist for a given message name
  (across all correlation values).
  """
  @spec has_subscriptions_for_message?(String.t()) :: boolean()
  def has_subscriptions_for_message?(message_name) do
    match_pattern = {{message_name, :_}, :_}
    :ets.match(@table_name, match_pattern) != []
  end

  @doc """
  Returns `true` once the resume pipeline has completed and all PIs
  have re-registered their message subscriptions.
  """
  @spec ready?() :: boolean()
  def ready? do
    GenServer.call(__MODULE__, :ready?)
  end

  @doc """
  Called by the resume pipeline after all PIs have been restored.

  Flips the readiness flag so the engine starts accepting external
  message triggers.
  """
  @spec mark_ready() :: :ok
  def mark_ready do
    GenServer.call(__MODULE__, :mark_ready)
  end

  @doc """
  Reset state — used by tests to clear subscriptions between runs.
  """
  @spec reset_state() :: :ok
  def reset_state do
    :ets.delete_all_objects(@table_name)
    :ets.delete_all_objects(@process_instance_index_table)
    GenServer.call(__MODULE__, :reset_ready)
    :ok
  end

  # -------------------------------------------------------------------
  # GenServer callbacks
  # -------------------------------------------------------------------

  @impl true
  def init(_opts) do
    table =
      :ets.new(@table_name, [
        :bag,
        :public,
        :named_table,
        read_concurrency: true,
        write_concurrency: true
      ])

    index_table =
      :ets.new(@process_instance_index_table, [
        :bag,
        :public,
        :named_table,
        read_concurrency: true,
        write_concurrency: true
      ])

    {:ok, %{table: table, index_table: index_table, ready: false}}
  end

  @impl true
  def handle_call(:ready?, _from, state) do
    {:reply, state.ready, state}
  end

  @impl true
  def handle_call(:mark_ready, _from, state) do
    Logger.info("MessageSubscriptions: marked as ready — accepting message triggers")
    {:reply, :ok, %{state | ready: true}}
  end

  @impl true
  def handle_call(:reset_ready, _from, state) do
    {:reply, :ok, %{state | ready: false}}
  end

  # -------------------------------------------------------------------
  # Private helpers
  # -------------------------------------------------------------------

  defp delete_matching_subscription(key, subscription_id) do
    @table_name
    |> :ets.lookup(key)
    |> Enum.filter(fn {_key, subscription} -> subscription.subscription_id == subscription_id end)
    |> Enum.each(fn {lookup_key, subscription} ->
      :ets.delete_object(@table_name, {lookup_key, subscription})
    end)
  end

  defp generate_id do
    "msub_" <> (:crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower))
  end

  defp drain_pending_messages(subscription) do
    alias EvilEngine.Events.MessagePersistence

    case MessagePersistence.adapter() do
      nil ->
        :ok

      adapter ->
        correlation =
          case subscription.expected_correlation_value do
            :none -> nil
            value -> value
          end

        drain_from_adapter(adapter, subscription, correlation)
    end
  rescue
    exception ->
      Logger.warning(
        "MessageSubscriptions: drain_pending_messages failed: #{Exception.message(exception)}"
      )
  end

  defp drain_from_adapter(adapter, subscription, correlation) do
    case adapter.find_pending_messages(subscription.message_name, correlation) do
      {:ok, pending_rows} ->
        deliver_pending_rows(adapter, subscription, pending_rows)

      {:error, reason} ->
        Logger.warning(
          "MessageSubscriptions: failed to drain pending messages: #{inspect(reason)}"
        )
    end
  end

  defp deliver_pending_rows(adapter, subscription, rows) do
    alias EvilEngine.Events.EngineEventBus
    alias EvilEngine.Types.Event

    Enum.each(rows, fn row ->
      case adapter.mark_pending_delivered(row.id) do
        :ok ->
          send(subscription.via_pid, {:message_arrived, row.message_id, row.payload, nil})

          EngineEventBus.publish(%Event.MessageArrived{
            message_id: row.message_id,
            message_name: subscription.message_name,
            correlation_value: row.correlation_value,
            payload: row.payload,
            process_instance_id: subscription.process_instance_id,
            flow_node_instance_id: subscription.flow_node_instance_id,
            lane_name: subscription.lane_name,
            occurred_at: DateTime.utc_now()
          })

          adapter.append_message_correlation(row.message_id, %{
            process_instance_id: subscription.process_instance_id,
            flow_node_instance_id: subscription.flow_node_instance_id,
            delivered_at: DateTime.utc_now() |> DateTime.to_iso8601()
          })

          Logger.debug(
            "MessageSubscriptions: drained pending message #{row.message_id} " <>
              "to subscription #{subscription.subscription_id}"
          )

        {:error, _reason} ->
          Logger.debug("MessageSubscriptions: pending message #{row.message_id} already claimed")
      end
    end)
  end
end
