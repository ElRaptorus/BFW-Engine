defmodule BfwEngine.Events.SignalSubscriptions do
  @moduledoc """
  In-memory subscription registry for BPMN Signal Events.

  Manages an ETS `:bag` table keyed by `signal_name` for O(1) lookup
  on publish. Each entry is a `Subscription` struct representing a
  waiting catch event or boundary event.

  Unlike `MessageSubscriptions`, signals have no correlation dimension —
  lookups are by `signal_name` only.

  ## Readiness gate

  After an engine restart, PIs resume and re-register their subscriptions.
  The registry starts in a "not ready" state; `POST /signals/:name/trigger`
  returns 503 until `mark_ready/0` is called by the resume pipeline.
  """

  use GenServer

  require Logger

  @table_name :bfw_engine_signal_subscriptions
  @process_instance_index_table :bfw_engine_signal_subscriptions_by_process_instance

  # -------------------------------------------------------------------
  # Subscription struct
  # -------------------------------------------------------------------

  defmodule Subscription do
    @moduledoc "A single signal subscription entry stored in the ETS table."

    @type kind :: :intermediate_catch | :boundary | :event_subprocess_start

    @type t :: %__MODULE__{
            subscription_id: String.t(),
            process_instance_id: String.t(),
            flow_node_instance_id: String.t(),
            flow_node_id: String.t(),
            signal_name: String.t(),
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
      :signal_name,
      :kind,
      :registered_at,
      :via_pid
    ]

    defstruct [
      :subscription_id,
      :process_instance_id,
      :flow_node_instance_id,
      :flow_node_id,
      :signal_name,
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
  Register a signal subscription.

  After inserting into ETS, drains any matching pending signals from
  the persistence layer. Returns `{:ok, subscription_id}`.
  """
  @spec register(map()) :: {:ok, String.t()}
  def register(params) do
    subscription = %Subscription{
      subscription_id: generate_id(),
      process_instance_id: params.process_instance_id,
      flow_node_instance_id: params.flow_node_instance_id,
      flow_node_id: params.flow_node_id,
      signal_name: params.signal_name,
      kind: params.kind,
      registered_at: DateTime.utc_now(),
      via_pid: params.via_pid,
      lane_name: Map.get(params, :lane_name),
      root_process_instance_id:
        Map.get(params, :root_process_instance_id) || params.process_instance_id
    }

    :ets.insert(@table_name, {subscription.signal_name, subscription})

    :ets.insert(
      @process_instance_index_table,
      {subscription.process_instance_id, subscription.signal_name, subscription.subscription_id}
    )

    Logger.debug(
      "SignalSubscriptions: registered #{subscription.subscription_id} " <>
        "for signal=#{subscription.signal_name} " <>
        "kind=#{subscription.kind} pi=#{subscription.process_instance_id}"
    )

    drain_pending_signals(subscription)

    {:ok, subscription.subscription_id}
  end

  @doc """
  Remove a subscription by its ID.
  """
  @spec unregister(String.t()) :: :ok
  def unregister(subscription_id) do
    @table_name
    |> :ets.tab2list()
    |> Enum.filter(fn {_key, subscription} -> subscription.subscription_id == subscription_id end)
    |> Enum.each(fn {key, subscription} ->
      :ets.delete_object(@table_name, {key, subscription})

      :ets.delete_object(
        @process_instance_index_table,
        {subscription.process_instance_id, key, subscription.subscription_id}
      )
    end)

    :ok
  end

  @doc """
  Bulk-remove all subscriptions for a process instance.
  """
  @spec unregister_all_for_process_instance(String.t()) :: :ok
  def unregister_all_for_process_instance(process_instance_id) do
    index_entries = :ets.lookup(@process_instance_index_table, process_instance_id)

    Enum.each(index_entries, fn {indexed_process_instance_id, signal_name, subscription_id} ->
      delete_matching_subscription(signal_name, subscription_id)

      :ets.delete_object(
        @process_instance_index_table,
        {indexed_process_instance_id, signal_name, subscription_id}
      )
    end)

    unless index_entries == [] do
      Logger.debug(
        "SignalSubscriptions: bulk-removed #{Enum.count(index_entries)} subscriptions for PI #{process_instance_id}"
      )
    end

    :ok
  end

  @doc """
  Look up all subscriptions matching a signal name.

  Returns all matching `Subscription` structs (broadcast to all).
  """
  @spec lookup(String.t()) :: [Subscription.t()]
  def lookup(signal_name) do
    @table_name
    |> :ets.lookup(signal_name)
    |> Enum.map(fn {_key, subscription} -> subscription end)
  end

  @doc """
  Returns `true` once the resume pipeline has completed and all PIs
  have re-registered their signal subscriptions.
  """
  @spec ready?() :: boolean()
  def ready? do
    GenServer.call(__MODULE__, :ready?)
  end

  @doc """
  Called by the resume pipeline after all PIs have been restored.
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
    Logger.info("SignalSubscriptions: marked as ready — accepting signal triggers")
    {:reply, :ok, %{state | ready: true}}
  end

  @impl true
  def handle_call(:reset_ready, _from, state) do
    {:reply, :ok, %{state | ready: false}}
  end

  # -------------------------------------------------------------------
  # Private helpers
  # -------------------------------------------------------------------

  defp delete_matching_subscription(signal_name, subscription_id) do
    @table_name
    |> :ets.lookup(signal_name)
    |> Enum.filter(fn {_name, subscription} ->
      subscription.subscription_id == subscription_id
    end)
    |> Enum.each(fn {lookup_name, subscription} ->
      :ets.delete_object(@table_name, {lookup_name, subscription})
    end)
  end

  defp generate_id do
    "ssub_" <> (:crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower))
  end

  defp drain_pending_signals(subscription) do
    alias BfwEngine.Events.SignalPersistence

    case SignalPersistence.adapter() do
      nil ->
        :ok

      adapter ->
        drain_from_adapter(adapter, subscription)
    end
  rescue
    exception ->
      Logger.warning(
        "SignalSubscriptions: drain_pending_signals failed: #{Exception.message(exception)}"
      )
  end

  defp drain_from_adapter(adapter, subscription) do
    case adapter.find_pending_signals(subscription.signal_name) do
      {:ok, pending_rows} ->
        deliver_pending_rows(adapter, subscription, pending_rows)

      {:error, reason} ->
        Logger.warning("SignalSubscriptions: failed to drain pending signals: #{inspect(reason)}")
    end
  end

  defp deliver_pending_rows(adapter, subscription, rows) do
    alias BfwEngine.Events.EngineEventBus
    alias BfwEngine.Types.Event

    Enum.each(rows, fn row ->
      case adapter.mark_pending_delivered(row.id) do
        :ok ->
          send(subscription.via_pid, {:signal_arrived, row.signal_id, nil})

          EngineEventBus.publish(%Event.SignalArrived{
            signal_id: row.signal_id,
            signal_name: subscription.signal_name,
            process_instance_id: subscription.process_instance_id,
            flow_node_instance_id: subscription.flow_node_instance_id,
            lane_name: subscription.lane_name,
            root_process_instance_id: subscription.root_process_instance_id,
            occurred_at: DateTime.utc_now()
          })

          adapter.append_signal_delivery(row.signal_id, %{
            process_instance_id: subscription.process_instance_id,
            flow_node_instance_id: subscription.flow_node_instance_id,
            delivered_at: DateTime.utc_now() |> DateTime.to_iso8601()
          })

          Logger.debug(
            "SignalSubscriptions: drained pending signal #{row.signal_id} " <>
              "to subscription #{subscription.subscription_id}"
          )

        {:error, reason} ->
          Logger.debug(
            "SignalSubscriptions: pending signal #{row.signal_id} already claimed: #{inspect(reason)}"
          )
      end
    end)
  end
end
