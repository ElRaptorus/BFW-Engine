defmodule BfwEngine.Events.MessageSubscriptions do
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
  handled by `BfwEngine.Events.SignalSubscriptions`; escalations use a
  scope-chain walker (Phase 4), not a subscription registry.
  """

  use GenServer

  alias BfwEngine.Events.CancelledFlowNodeInstances

  require Logger

  @table_name :bfw_engine_message_subscriptions
  @process_instance_index_table :bfw_engine_message_subscriptions_by_process_instance
  # Survives a restart of this server: the resume pipeline marks readiness once per boot.
  @ready_key {__MODULE__, :ready}
  # Drain passes per registration: the second pass only runs after every row of the first was taken.
  @drain_attempts 2

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
            lane_name: String.t() | nil,
            root_process_instance_id: String.t() | nil
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
      :lane_name,
      :root_process_instance_id
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
  the persistence layer. Returns `{:ok, subscription_id}`. For a flow node
  instance marked in `CancelledFlowNodeInstances` nothing is registered or
  drained, and the returned id names no subscription.
  """
  @spec register(map()) :: {:ok, String.t()}
  def register(params) do
    if CancelledFlowNodeInstances.cancelled?(params.flow_node_instance_id) do
      {:ok, generate_id()}
    else
      insert_and_drain(params)
    end
  end

  defp insert_and_drain(params) do
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
      lane_name: Map.get(params, :lane_name),
      root_process_instance_id:
        Map.get(params, :root_process_instance_id) || params.process_instance_id
    }

    insert_subscription(subscription)

    Logger.debug(
      "MessageSubscriptions: registered #{subscription.subscription_id} " <>
        "for message=#{subscription.message_name} " <>
        "correlation=#{inspect(subscription.expected_correlation_value)} " <>
        "kind=#{subscription.kind} pi=#{subscription.process_instance_id}"
    )

    # The mark may land between the check in `register/1` and the insert.
    if CancelledFlowNodeInstances.cancelled?(subscription.flow_node_instance_id) do
      unregister(subscription.subscription_id)
    else
      drain_pending_messages(subscription)
    end

    {:ok, subscription.subscription_id}
  end

  @doc """
  Atomically take one subscription out of the registry.

  Returns `true` only for the caller that removed it. A publisher claims a
  one-shot subscription (catch, boundary, receive task) before delivering,
  so two publications racing for the same waiter deliver exactly once. A
  caller that loses the claim must not deliver.
  """
  @spec claim(Subscription.t()) :: boolean()
  def claim(%Subscription{} = subscription) do
    key = {subscription.message_name, subscription.expected_correlation_value}

    match_specification = [
      {{key, %{subscription_id: subscription.subscription_id}}, [], [true]}
    ]

    case :ets.select_delete(@table_name, match_specification) do
      0 ->
        false

      _claimed ->
        :ets.delete_object(
          @process_instance_index_table,
          {subscription.process_instance_id, key, subscription.subscription_id}
        )

        true
    end
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
  Remove every subscription registered for a flow node instance.

  The process instance calls this whenever it cancels, interrupts, or
  aborts a flow node instance, so a handler cancelled before it reported
  its `subscription_id` leaves no subscription behind. Event Subprocess
  start subscriptions carry a start event id, never a flow node instance
  id, and are not affected.
  """
  @spec unregister_all_for_flow_node_instance(String.t()) :: :ok
  def unregister_all_for_flow_node_instance(flow_node_instance_id)
      when is_binary(flow_node_instance_id) do
    # ponytail: full-table scan, O(subscriptions) per call; add an index keyed by flow node
    # instance id (like the process instance index) if cancel paths get hot.
    @table_name
    |> :ets.match_object({:_, %{flow_node_instance_id: flow_node_instance_id}})
    |> Enum.each(&delete_subscription_entry/1)
  end

  @doc """
  Remove the given subscriptions. Publishers call this for subscriptions
  whose `via_pid` is no longer alive, so a dead waiter is never counted as
  a delivery.
  """
  @spec prune([Subscription.t()]) :: :ok
  def prune(subscriptions) do
    Enum.each(subscriptions, fn subscription ->
      delete_subscription_entry(
        {{subscription.message_name, subscription.expected_correlation_value}, subscription}
      )
    end)
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
  def ready?, do: :persistent_term.get(@ready_key, false)

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
  Clears the readiness flag. The execution application calls this at start,
  so a restarted application refuses message triggers until its resume run
  calls `mark_ready/0` again.
  """
  @spec mark_not_ready() :: :ok
  def mark_not_ready do
    GenServer.call(__MODULE__, :mark_not_ready)
  end

  @doc """
  Block until `mark_ready/0` has been called, at most `timeout` milliseconds.

  In-engine publishers call this so a message thrown while the engine is still
  resuming waits for the re-registered subscriptions instead of falling
  through to a start event. Returns `:ok` or `{:error, :timeout}`.
  """
  @spec await_ready(timeout()) :: :ok | {:error, :timeout}
  def await_ready(timeout) do
    if ready?(), do: :ok, else: GenServer.call(__MODULE__, :await_ready, timeout)
  catch
    :exit, {:timeout, _call} -> {:error, :timeout}
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

    {:ok, %{table: table, index_table: index_table, ready: ready?(), ready_waiters: []}}
  end

  @impl true
  def handle_call(:mark_ready, _from, state) do
    Logger.info("MessageSubscriptions: marked as ready — accepting message triggers")
    :persistent_term.put(@ready_key, true)
    Enum.each(state.ready_waiters, &GenServer.reply(&1, :ok))
    {:reply, :ok, %{state | ready: true, ready_waiters: []}}
  end

  def handle_call(:mark_not_ready, _from, state) do
    :persistent_term.erase(@ready_key)
    {:reply, :ok, %{state | ready: false}}
  end

  def handle_call(:await_ready, _from, %{ready: true} = state), do: {:reply, :ok, state}

  def handle_call(:await_ready, from, state) do
    {:noreply, %{state | ready_waiters: [from | state.ready_waiters]}}
  end

  # -------------------------------------------------------------------
  # Private helpers
  # -------------------------------------------------------------------

  defp delete_subscription_entry({key, subscription} = entry) do
    :ets.delete_object(@table_name, entry)

    :ets.delete_object(
      @process_instance_index_table,
      {subscription.process_instance_id, key, subscription.subscription_id}
    )
  end

  defp delete_matching_subscription(key, subscription_id) do
    @table_name
    |> :ets.lookup(key)
    |> Enum.filter(fn {_key, subscription} -> subscription.subscription_id == subscription_id end)
    |> Enum.each(fn {lookup_key, subscription} ->
      :ets.delete_object(@table_name, {lookup_key, subscription})
    end)
  end

  defp insert_subscription(subscription) do
    key = {subscription.message_name, subscription.expected_correlation_value}
    :ets.insert(@table_name, {key, subscription})

    :ets.insert(
      @process_instance_index_table,
      {subscription.process_instance_id, key, subscription.subscription_id}
    )
  end

  defp generate_id do
    "msub_" <> (:crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower))
  end

  defp drain_pending_messages(subscription) do
    alias BfwEngine.Events.MessagePersistence

    case MessagePersistence.adapter() do
      nil ->
        :ok

      adapter ->
        correlation =
          case subscription.expected_correlation_value do
            :none -> nil
            value -> value
          end

        drain_from_adapter(adapter, subscription, correlation, @drain_attempts)
    end
  rescue
    exception ->
      Logger.warning(
        "MessageSubscriptions: drain_pending_messages failed: #{Exception.message(exception)}"
      )
  end

  # A registration takes at most one pending message, the oldest: a catch
  # event consumes a single message. A one-shot subscription is claimed first
  # so a live publication racing this drain cannot deliver a second message;
  # when the claim is lost the pending rows stay pending. When no row can be
  # marked (another drain took them), the subscription goes back into the
  # registry and the drain looks once more.
  defp drain_from_adapter(adapter, subscription, correlation, attempts_left) do
    case adapter.find_pending_messages(subscription.message_name, correlation) do
      {:ok, []} ->
        :ok

      {:ok, pending_rows} ->
        drain_rows(adapter, subscription, correlation, pending_rows, attempts_left)

      {:error, reason} ->
        Logger.warning(
          "MessageSubscriptions: failed to drain pending messages: #{inspect(reason)}"
        )
    end
  end

  defp drain_rows(
         adapter,
         %Subscription{kind: :event_subprocess_start} = subscription,
         _,
         rows,
         _
       ) do
    deliver_first_pending_row(adapter, subscription, rows)
    :ok
  end

  defp drain_rows(adapter, subscription, correlation, rows, attempts_left) do
    if claim(subscription) do
      case deliver_first_pending_row(adapter, subscription, rows) do
        :delivered ->
          :ok

        :none_marked ->
          insert_subscription(subscription)
          retry_drain(adapter, subscription, correlation, attempts_left)
      end
    else
      :ok
    end
  end

  defp retry_drain(_adapter, _subscription, _correlation, attempts_left)
       when attempts_left <= 1,
       do: :ok

  defp retry_drain(adapter, subscription, correlation, attempts_left) do
    drain_from_adapter(adapter, subscription, correlation, attempts_left - 1)
  end

  defp deliver_first_pending_row(adapter, subscription, rows) do
    alias BfwEngine.Events.EngineEventBus
    alias BfwEngine.Types.Event

    Enum.reduce_while(rows, :none_marked, fn row, _result ->
      case adapter.mark_pending_delivered(row.id) do
        :ok ->
          send(subscription.via_pid, pending_delivery_message(subscription, row))

          EngineEventBus.publish(%Event.MessageArrived{
            message_id: row.message_id,
            message_name: subscription.message_name,
            correlation_value: row.correlation_value,
            payload: row.payload,
            process_instance_id: subscription.process_instance_id,
            flow_node_instance_id: subscription.flow_node_instance_id,
            lane_name: subscription.lane_name,
            root_process_instance_id: subscription.root_process_instance_id,
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

          {:halt, :delivered}

        {:error, _reason} ->
          Logger.debug("MessageSubscriptions: pending message #{row.message_id} already claimed")
          {:cont, :none_marked}
      end
    end)
  end

  defp pending_delivery_message(%Subscription{kind: :event_subprocess_start} = subscription, row),
    do: {:event_subprocess_message, subscription.flow_node_id, row.payload}

  defp pending_delivery_message(_subscription, row),
    do: {:message_arrived, row.message_id, row.payload, nil}
end
