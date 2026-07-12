defmodule EvilEngine.BPMN.ModelCache do
  @moduledoc """
  ETS-backed in-memory cache for parsed BPMN `%Definitions{}` ASTs.

  Keyed by `process_version_id` (UUID string). Reads go directly to
  ETS (`read_concurrency: true`); writes are serialized through the
  GenServer to avoid race conditions on cache-miss reload.

  ## Single-flight semantics

  When multiple callers miss ETS for the same `process_version_id`
  simultaneously (e.g. after a node restart), only one backend load is
  initiated. All additional callers for that key are registered as
  **waiters** in the GenServer state and replied to when the load
  completes. This prevents a cache stampede from firing N redundant
  XML-parse + FEEL-compile cycles for the same version.

  The expensive work (XML parse + expression compile) runs inside a
  `Task`, keeping the GenServer responsive to requests for other keys
  while the load is in progress.

  ## Loader configuration

  The optional `:loader` config (`{module, function}` tuple) is called
  on cache miss to retrieve raw XML for re-parse. Phase 0 ships with
  no loader (returns `{:error, :not_found}`).

      config :core_bpmn, :model_cache_loader, {MyPersistenceModule, :load_bpmn_xml}

  The function is called as `apply(mod, fun, [process_version_id])` and
  must return `{:ok, xml_binary}` or `{:error, reason}`.
  """

  use GenServer

  alias EvilEngine.BPMN.Model.Definitions
  alias EvilEngine.BPMN.Model.EventDefinition
  alias EvilEngine.BPMN.Model.FlowNode
  alias EvilEngine.BPMN.Model.Lane
  alias EvilEngine.BPMN.Model.Process, as: BpmnProcess

  @table :evil_engine_model_cache
  @message_start_index :evil_engine_message_start_index
  @signal_start_index :evil_engine_signal_start_index

  # -------------------------------------------------------------------
  # Client API
  # -------------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Insert a definitions struct if not already cached. Returns `:ok`."
  @spec put_new(String.t(), Definitions.t()) :: :ok
  def put_new(process_version_id, %Definitions{} = definitions) do
    inserted = :ets.insert_new(@table, {process_version_id, definitions})

    if inserted do
      index_start_events(process_version_id, definitions)
    end

    :ok
  end

  @doc """
  Look up a cached definitions struct.

  On miss, calls the configured loader (if any) to re-parse from raw XML.
  Returns `{:ok, definitions}` or `{:error, :not_found}`.

  Uses single-flight semantics: if multiple callers miss ETS for the
  same `process_version_id` concurrently, only one backend load is
  performed and all callers receive the same result.
  """
  @spec fetch(String.t()) :: {:ok, Definitions.t()} | {:error, :not_found | term()}
  def fetch(process_version_id) do
    case :ets.lookup(@table, process_version_id) do
      [{^process_version_id, definitions}] ->
        {:ok, definitions}

      [] ->
        GenServer.call(__MODULE__, {:load_and_cache, process_version_id})
    end
  end

  @doc "Same as `fetch/1` but returns `nil` on miss instead of an error tuple."
  @spec get(String.t()) :: Definitions.t() | nil
  def get(process_version_id) do
    case fetch(process_version_id) do
      {:ok, definitions} -> definitions
      _ -> nil
    end
  end

  @doc """
  Build a synthetic `%Process{}` from an embedded subprocess's inner scope.

  Fetches the parent model from cache, locates the `%FlowNode{type: :sub_process}`
  with the given ID (searching recursively through nested subprocesses), and
  returns a synthetic process struct suitable for starting a child PI.

  The synthetic process uses a composite ID:
  `"\#{parent_process_id}__subprocess__\#{subprocess_node_id}"`.
  """
  @spec fetch_subprocess_model(String.t(), String.t()) ::
          {:ok, BpmnProcess.t(), Definitions.t()} | {:error, :not_found | :subprocess_not_found}
  def fetch_subprocess_model(process_version_id, subprocess_node_id) do
    case fetch(process_version_id) do
      {:ok, definitions} ->
        case find_subprocess_in_definitions(definitions, subprocess_node_id) do
          {:ok, synthetic_process} -> {:ok, synthetic_process, definitions}
          error -> error
        end

      error ->
        error
    end
  end

  @doc "Remove a cached entry. Returns `:ok`."
  @spec delete(String.t()) :: :ok
  def delete(process_version_id) do
    remove_message_start_index_entries(process_version_id)
    remove_signal_start_index_entries(process_version_id)
    :ets.delete(@table, process_version_id)
    :ok
  end

  @doc """
  Clear all cached entries (for test isolation).

  Does not cancel in-flight loads. Because tests run with `async: false`,
  no in-flight loads exist when this is called from `setup`.
  """
  @spec reset_state() :: :ok
  def reset_state do
    :ets.delete_all_objects(@table)
    :ets.delete_all_objects(@message_start_index)
    :ets.delete_all_objects(@signal_start_index)
    :ok
  end

  @doc "Return all cached process version IDs."
  @spec list_cached_ids() :: [String.t()]
  def list_cached_ids do
    :ets.select(@table, [{{:"$1", :_}, [], [:"$1"]}])
  end

  @doc """
  Find all deployed Message Start Events matching a message name.

  Returns a list of `{process_id, process_version_id, start_event_id}`
  tuples. Used by `MessagePublisher` for catch-wins-over-Start gating.
  """
  @spec find_message_start_events(String.t()) ::
          [{String.t(), String.t(), String.t()}]
  def find_message_start_events(message_name) do
    @message_start_index
    |> :ets.lookup({:message_start, message_name})
    |> Enum.map(fn {_key, entry} -> entry end)
  end

  @doc """
  Find all deployed Signal Start Events matching a signal name.

  Returns a list of `{process_id, process_version_id, start_event_id}`
  tuples. Used by `SignalPublisher` for true-broadcast start event firing.
  """
  @spec find_signal_start_events(String.t()) ::
          [{String.t(), String.t(), String.t()}]
  def find_signal_start_events(signal_name) do
    @signal_start_index
    |> :ets.lookup({:signal_start, signal_name})
    |> Enum.map(fn {_key, entry} -> entry end)
  end

  # -------------------------------------------------------------------
  # GenServer callbacks
  # -------------------------------------------------------------------

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])

    _message_idx =
      :ets.new(@message_start_index, [
        :named_table,
        :bag,
        :public,
        read_concurrency: true
      ])

    _signal_idx =
      :ets.new(@signal_start_index, [
        :named_table,
        :bag,
        :public,
        read_concurrency: true
      ])

    {:ok, %{table: table, inflight: %{}, ref_to_id: %{}}}
  end

  @impl true
  def handle_call({:load_and_cache, id}, from, state) do
    case :ets.lookup(@table, id) do
      [{^id, definitions}] ->
        # Filled by a concurrent load while we were queuing in the mailbox.
        {:reply, {:ok, definitions}, state}

      [] ->
        handle_inflight(id, from, state)
    end
  end

  # Task completed normally — result delivered as {ref, result}.
  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    case Map.pop(state.ref_to_id, ref) do
      {nil, _} ->
        # Not a ref we issued (e.g. stale message after reset_state). Ignore.
        {:noreply, state}

      {id, new_ref_to_id} ->
        Process.demonitor(ref, [:flush])

        %{waiters: waiters} = Map.fetch!(state.inflight, id)
        _cached = cache_loaded_definitions(id, result)
        Enum.each(waiters, &GenServer.reply(&1, result))

        new_state = %{
          state
          | inflight: Map.delete(state.inflight, id),
            ref_to_id: new_ref_to_id
        }

        {:noreply, new_state}
    end
  end

  # Task process was killed before it could send a result (e.g. OOM).
  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) when is_reference(ref) do
    case Map.pop(state.ref_to_id, ref) do
      {nil, _} ->
        {:noreply, state}

      {id, new_ref_to_id} ->
        %{waiters: waiters} = Map.fetch!(state.inflight, id)
        Enum.each(waiters, &GenServer.reply(&1, {:error, {:load_task_crashed, reason}}))

        new_state = %{
          state
          | inflight: Map.delete(state.inflight, id),
            ref_to_id: new_ref_to_id
        }

        {:noreply, new_state}
    end
  end

  # -------------------------------------------------------------------
  # Private helpers
  # -------------------------------------------------------------------

  defp handle_inflight(id, from, state) do
    case Map.get(state.inflight, id) do
      %{waiters: waiters} ->
        # A load for this key is already in flight — register as a waiter.
        new_state = put_in(state, [:inflight, id, :waiters], [from | waiters])
        {:noreply, new_state}

      nil ->
        # First miss for this key — spawn a Task and register as the first waiter.
        task = Task.async(fn -> safe_load(id) end)
        entry = %{task_ref: task.ref, waiters: [from]}

        new_state =
          state
          |> put_in([:inflight, id], entry)
          |> put_in([:ref_to_id, task.ref], id)

        {:noreply, new_state}
    end
  end

  defp safe_load(id) do
    load_from_backend(id)
  rescue
    exception -> {:error, {:exception, Exception.message(exception)}}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp load_from_backend(id) do
    case Application.get_env(:core_bpmn, :model_cache_loader) do
      {mod, fun} ->
        case apply(mod, fun, [id]) do
          {:ok, xml} when is_binary(xml) ->
            EvilEngine.BPMN.parse_and_validate(xml)

          error ->
            error
        end

      _ ->
        {:error, :not_found}
    end
  end

  defp cache_loaded_definitions(id, {:ok, definitions}) do
    if :ets.insert_new(@table, {id, definitions}) do
      index_start_events(id, definitions)
    end
  end

  defp cache_loaded_definitions(_id, _error), do: :ok

  defp index_start_events(process_version_id, definitions) do
    _message_entries = index_message_start_events(process_version_id, definitions)
    _signal_entries = index_signal_start_events(process_version_id, definitions)
    :ok
  end

  # -------------------------------------------------------------------
  # Private: Message Start Event index
  # -------------------------------------------------------------------

  defp index_message_start_events(process_version_id, %Definitions{} = definitions) do
    for process <- definitions.processes,
        flow_node <- process.flow_nodes,
        flow_node.type == :start_event,
        match?(%EventDefinition.Message{}, flow_node.type_data.event_definition) do
      message_ref = flow_node.type_data.event_definition.message_ref
      message_name = resolve_message_name_from_definitions(definitions, message_ref)

      if message_name do
        entry = {process.id, process_version_id, flow_node.id}
        :ets.insert(@message_start_index, {{:message_start, message_name}, entry})
      end
    end
  end

  defp remove_message_start_index_entries(process_version_id) do
    @message_start_index
    |> :ets.tab2list()
    |> Enum.filter(fn {_key, {_process_id, pvid, _start_event_id}} ->
      pvid == process_version_id
    end)
    |> Enum.each(fn entry -> :ets.delete_object(@message_start_index, entry) end)
  end

  defp resolve_message_name_from_definitions(%Definitions{messages: messages}, message_ref)
       when is_binary(message_ref) do
    case Enum.find(messages, fn msg -> msg.id == message_ref end) do
      nil -> nil
      message_def -> message_def.name
    end
  end

  defp resolve_message_name_from_definitions(_definitions, _message_ref), do: nil

  # -------------------------------------------------------------------
  # Private: Signal Start Event index
  # -------------------------------------------------------------------

  defp index_signal_start_events(process_version_id, %Definitions{} = definitions) do
    for process <- definitions.processes,
        flow_node <- process.flow_nodes,
        flow_node.type == :start_event,
        match?(%EventDefinition.Signal{}, flow_node.type_data.event_definition) do
      signal_ref = flow_node.type_data.event_definition.signal_ref
      signal_name = resolve_signal_name_from_definitions(definitions, signal_ref)

      if signal_name do
        entry = {process.id, process_version_id, flow_node.id}
        :ets.insert(@signal_start_index, {{:signal_start, signal_name}, entry})
      end
    end
  end

  defp remove_signal_start_index_entries(process_version_id) do
    @signal_start_index
    |> :ets.tab2list()
    |> Enum.filter(fn {_key, {_process_id, pvid, _start_event_id}} ->
      pvid == process_version_id
    end)
    |> Enum.each(fn entry -> :ets.delete_object(@signal_start_index, entry) end)
  end

  defp resolve_signal_name_from_definitions(%Definitions{signals: signals}, signal_ref)
       when is_binary(signal_ref) do
    case Enum.find(signals, fn sig -> sig.id == signal_ref end) do
      nil -> nil
      signal_def -> signal_def.name
    end
  end

  defp resolve_signal_name_from_definitions(_definitions, _signal_ref), do: nil

  # -------------------------------------------------------------------
  # Private: Subprocess model extraction
  # -------------------------------------------------------------------

  defp find_subprocess_in_definitions(%Definitions{processes: processes}, subprocess_node_id) do
    result =
      Enum.find_value(processes, fn process ->
        find_subprocess_node(process.flow_nodes, subprocess_node_id, process)
      end)

    case result do
      nil -> {:error, :subprocess_not_found}
      synthetic_process -> {:ok, synthetic_process}
    end
  end

  defp find_subprocess_node(flow_nodes, subprocess_node_id, parent_process) do
    Enum.find_value(flow_nodes, fn
      %FlowNode{id: ^subprocess_node_id, type: :sub_process} = node ->
        build_synthetic_process(node, parent_process)

      %FlowNode{type: :sub_process, type_data: %{flow_nodes: inner_nodes}} ->
        find_subprocess_node(inner_nodes, subprocess_node_id, parent_process)

      _other ->
        nil
    end)
  end

  defp build_synthetic_process(subprocess_node, parent_process) do
    inherited_lanes = inherit_parent_lane(subprocess_node, parent_process)

    %BpmnProcess{
      id: "#{parent_process.id}__subprocess__#{subprocess_node.id}",
      name: subprocess_node.name,
      version: parent_process.version,
      is_executable: true,
      is_transaction_scope: Map.get(subprocess_node.type_data, :is_transaction, false),
      flow_nodes: subprocess_node.type_data.flow_nodes,
      sequence_flows: subprocess_node.type_data.sequence_flows,
      data_objects: subprocess_node.type_data.data_objects,
      data_object_references: subprocess_node.type_data.data_object_references,
      lanes: inherited_lanes
    }
  end

  defp inherit_parent_lane(subprocess_node, parent_process) do
    parent_lane =
      Enum.find(parent_process.lanes, fn lane ->
        subprocess_node.id in (lane.flow_node_refs || [])
      end)

    case parent_lane do
      nil ->
        []

      %Lane{name: lane_name} ->
        inner_flow_node_ids =
          Enum.map(subprocess_node.type_data.flow_nodes, & &1.id)

        [%Lane{id: "inherited_lane__#{subprocess_node.id}", name: lane_name, flow_node_refs: inner_flow_node_ids}]
    end
  end
end
