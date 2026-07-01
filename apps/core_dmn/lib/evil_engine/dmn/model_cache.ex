defmodule EvilEngine.DMN.ModelCache do
  @moduledoc """
  ETS-backed in-memory cache for parsed DMN `%Definitions{}` ASTs.

  Keyed by `decision_version_id` (UUID string). Same single-flight
  semantics as `EvilEngine.BPMN.ModelCache` — see that module's
  documentation for design details.

  A secondary ETS table maintains a `namespace → decision_version_id`
  index for O(1) import resolution. Updated automatically on
  `put_new/2` and `delete/1`.
  """

  use GenServer

  alias EvilEngine.DMN.Model.Definitions

  @table :evil_engine_dmn_model_cache
  @namespace_index :evil_engine_dmn_namespace_index

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec put_new(String.t(), Definitions.t()) :: :ok
  def put_new(decision_version_id, %Definitions{} = definitions) do
    :ets.insert_new(@table, {decision_version_id, definitions})
    update_namespace_index(definitions.namespace, decision_version_id)
    :ok
  end

  @spec fetch(String.t()) :: {:ok, Definitions.t()} | {:error, :not_found | term()}
  def fetch(decision_version_id) do
    case :ets.lookup(@table, decision_version_id) do
      [{^decision_version_id, definitions}] ->
        :telemetry.execute(
          [:evil_engine, :dmn, :cache, :hit],
          %{count: 1},
          %{decision_version_id: decision_version_id}
        )

        {:ok, definitions}

      [] ->
        :telemetry.execute(
          [:evil_engine, :dmn, :cache, :miss],
          %{count: 1},
          %{decision_version_id: decision_version_id}
        )

        GenServer.call(__MODULE__, {:load_and_cache, decision_version_id})
    end
  end

  @spec get(String.t()) :: Definitions.t() | nil
  def get(decision_version_id) do
    case fetch(decision_version_id) do
      {:ok, definitions} -> definitions
      _ -> nil
    end
  end

  @spec delete(String.t()) :: :ok
  def delete(decision_version_id) do
    remove_from_namespace_index(decision_version_id)
    :ets.delete(@table, decision_version_id)
    :ok
  end

  @spec reset_state() :: :ok
  def reset_state do
    :ets.delete_all_objects(@table)
    :ets.delete_all_objects(@namespace_index)
    :ok
  end

  @spec list_cached_ids() :: [String.t()]
  def list_cached_ids do
    :ets.select(@table, [{{:"$1", :_}, [], [:"$1"]}])
  end

  @doc """
  Look up a cached `%Definitions{}` by its `targetNamespace` URI.

  Uses the secondary namespace index for O(1) lookup instead of
  scanning all cached entries. When multiple versions share a
  namespace, the most recently cached version wins.
  """
  @spec lookup_by_namespace(String.t()) :: {:ok, Definitions.t()} | {:error, :not_found}
  def lookup_by_namespace(namespace) when is_binary(namespace) do
    case :ets.lookup(@namespace_index, namespace) do
      [{^namespace, decision_version_id}] ->
        case :ets.lookup(@table, decision_version_id) do
          [{^decision_version_id, definitions}] -> {:ok, definitions}
          [] -> {:error, :not_found}
        end

      [] ->
        {:error, :not_found}
    end
  end

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    _namespace_index = :ets.new(@namespace_index, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{table: table, inflight: %{}, ref_to_id: %{}}}
  end

  @impl true
  def handle_call({:load_and_cache, id}, from, state) do
    case :ets.lookup(@table, id) do
      [{^id, definitions}] ->
        {:reply, {:ok, definitions}, state}

      [] ->
        handle_inflight(id, from, state)
    end
  end

  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    case Map.pop(state.ref_to_id, ref) do
      {nil, _} ->
        {:noreply, state}

      {id, new_ref_to_id} ->
        Process.demonitor(ref, [:flush])
        complete_inflight(id, result, %{state | ref_to_id: new_ref_to_id})
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) when is_reference(ref) do
    case Map.pop(state.ref_to_id, ref) do
      {nil, _} ->
        {:noreply, state}

      {id, new_ref_to_id} ->
        complete_inflight(id, {:error, {:load_task_crashed, reason}}, %{state | ref_to_id: new_ref_to_id})
    end
  end

  defp complete_inflight(id, result, state) do
    case Map.pop(state.inflight, id) do
      {nil, _} ->
        {:noreply, state}

      {%{waiters: waiters}, new_inflight} ->
        maybe_cache_result(id, result)
        Enum.each(waiters, &GenServer.reply(&1, result))
        {:noreply, %{state | inflight: new_inflight}}
    end
  end

  defp maybe_cache_result(id, {:ok, %Definitions{} = definitions}) do
    :ets.insert_new(@table, {id, definitions})
    update_namespace_index(definitions.namespace, id)
  end

  defp maybe_cache_result(_id, _error_result), do: :ok

  defp handle_inflight(id, from, state) do
    case Map.get(state.inflight, id) do
      %{waiters: waiters} ->
        new_state = put_in(state, [:inflight, id, :waiters], [from | waiters])
        {:noreply, new_state}

      nil ->
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
    case Application.get_env(:core_dmn, :model_cache_loader) do
      {mod, fun} ->
        case apply(mod, fun, [id]) do
          {:ok, xml} when is_binary(xml) ->
            EvilEngine.DMN.parse_and_validate(xml)

          error ->
            error
        end

      _ ->
        {:error, :not_found}
    end
  end

  defp update_namespace_index(nil, _decision_version_id), do: :ok

  defp update_namespace_index(namespace, decision_version_id) when is_binary(namespace) do
    :ets.insert(@namespace_index, {namespace, decision_version_id})
    :ok
  end

  defp remove_from_namespace_index(decision_version_id) do
    case :ets.lookup(@table, decision_version_id) do
      [{^decision_version_id, %Definitions{namespace: namespace}}] when not is_nil(namespace) ->
        case :ets.lookup(@namespace_index, namespace) do
          [{^namespace, ^decision_version_id}] ->
            :ets.delete(@namespace_index, namespace)
            backfill_namespace_index(namespace, decision_version_id)

          _ ->
            :ok
        end

      _ ->
        :ok
    end
  end

  defp backfill_namespace_index(namespace, deleted_version_id) do
    replacement =
      :ets.select(@table, [{{:"$1", :"$2"}, [], [{{:"$1", :"$2"}}]}])
      |> Enum.find(fn {version_id, %Definitions{namespace: ns}} ->
        ns == namespace and version_id != deleted_version_id
      end)

    case replacement do
      {version_id, _definitions} ->
        :ets.insert(@namespace_index, {namespace, version_id})

      nil ->
        :ok
    end
  end
end
