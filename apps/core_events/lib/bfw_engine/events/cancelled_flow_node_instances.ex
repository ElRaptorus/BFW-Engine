defmodule BfwEngine.Events.CancelledFlowNodeInstances do
  @moduledoc """
  Flow node instances whose handler their process instance has cancelled.

  A cancelled handler Task can still run for a moment (an exit signal is
  asynchronous, an Event-Based Gateway loser may still be entering), so it can
  register a message or signal subscription after the process instance
  removed that flow node instance's subscriptions. `MessageSubscriptions` and
  `SignalSubscriptions` refuse to register a marked flow node instance, and
  the publishers skip and prune its subscriptions.

  Each mark belongs to the process instance that set it and is removed when
  that process exits.
  """

  use GenServer

  # ponytail: node-local ETS table; a multi-node deployment needs the marks in shared state.
  @table_name :bfw_engine_cancelled_flow_node_instances

  @doc """
  Creates the mark table, owned by the calling process. `Events.Application`
  calls it before its supervisor starts, so the marks survive a restart of
  this server.
  """
  @spec create_table() :: :ok
  def create_table do
    _table =
      :ets.new(@table_name, [
        :set,
        :public,
        :named_table,
        read_concurrency: true,
        write_concurrency: true
      ])

    :ok
  end

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Marks `flow_node_instance_id` as cancelled by the calling process instance."
  @spec mark(String.t()) :: :ok
  def mark(flow_node_instance_id) when is_binary(flow_node_instance_id) do
    :ets.insert(@table_name, {flow_node_instance_id, self()})
    GenServer.cast(__MODULE__, {:watch, self()})
  end

  @doc "Returns `true` when `flow_node_instance_id` carries a cancel mark."
  @spec cancelled?(term()) :: boolean()
  def cancelled?(flow_node_instance_id) when is_binary(flow_node_instance_id),
    do: :ets.member(@table_name, flow_node_instance_id)

  def cancelled?(_flow_node_instance_id), do: false

  @impl true
  def init(_opts) do
    owners = MapSet.new(:ets.select(@table_name, [{{:_, :"$1"}, [], [:"$1"]}]))
    Enum.each(owners, &Process.monitor/1)
    {:ok, %{watched: owners}}
  end

  @impl true
  def handle_cast({:watch, owner}, state) do
    if MapSet.member?(state.watched, owner) do
      {:noreply, state}
    else
      Process.monitor(owner)
      {:noreply, %{state | watched: MapSet.put(state.watched, owner)}}
    end
  end

  @impl true
  # ponytail: marks live until their process instance exits and each exit scans
  # the whole table; a bag table keyed by owner would make cleanup proportional.
  def handle_info({:DOWN, _reference, :process, owner, _reason}, state) do
    :ets.match_delete(@table_name, {:_, owner})
    {:noreply, %{state | watched: MapSet.delete(state.watched, owner)}}
  end
end
