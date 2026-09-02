defmodule EvilEngine.Persistence.ExecutionAdapter do
  @moduledoc """
  Ash-backed implementation of `EvilEngine.Execution.Persistence`.

  Bridges the Core execution layer to the Peripheral persistence
  layer without violating dependency direction (Core never imports Peripheral).
  Configure via `:core_execution, :persistence_adapter`.

  Also serves as the `model_cache_loader` for `ModelCache` — when
  a cache miss occurs, `load_bpmn_xml/1` reads the raw XML from
  the `process_versions` table so the cache auto-heals without
  re-deployment.
  """

  @behaviour EvilEngine.Execution.Persistence

  require Ash.Query

  alias Ecto.Adapters.SQL, as: EctoSQL
  alias EvilEngine.Persistence.ProcessInstancePurge
  alias EvilEngine.Persistence.Repo
  alias EvilEngine.Persistence.Resources.DataObject, as: DataObjectResource
  alias EvilEngine.Persistence.Resources.DecisionVersion
  alias EvilEngine.Persistence.Resources.FlowNodeInstance
  alias EvilEngine.Persistence.Resources.GatewayPendingArrival
  alias EvilEngine.Persistence.Resources.ProcessInstance
  alias EvilEngine.Persistence.Resources.ProcessVersion

  @domain EvilEngine.Persistence.Api

  @state_running "running"
  @state_active "active"
  @state_waiting "waiting"
  @state_finished "finished"
  @flow_node_type_end_event "end_event"

  @doc "Persist a new process instance row."
  @impl true
  def create_process_instance(attributes) do
    case Ash.create(ProcessInstance, attributes, domain: @domain, authorize?: false) do
      {:ok, record} -> {:ok, %{id: record.id}}
      error -> error
    end
  end

  @doc "Update a process instance's state and metadata."
  @impl true
  def update_process_instance(id, changes) do
    with {:ok, record} <- Ash.get(ProcessInstance, id, domain: @domain, authorize?: false),
         {:ok, _updated} <-
           Ash.update(record, changes, domain: @domain, action: :update_state, authorize?: false) do
      :ok
    end
  end

  @doc "Persist a new flow node instance row."
  @impl true
  def create_flow_node_instance(attributes) do
    case Ash.create(FlowNodeInstance, attributes, domain: @domain, authorize?: false) do
      {:ok, record} -> {:ok, %{id: record.id}}
      error -> error
    end
  end

  @doc "Update a flow node instance via the specified Ash action."
  @impl true
  def update_flow_node_instance(id, action, changes) do
    with {:ok, record} <- Ash.get(FlowNodeInstance, id, domain: @domain, authorize?: false),
         {:ok, _updated} <-
           Ash.update(record, changes, domain: @domain, action: action, authorize?: false) do
      :ok
    end
  end

  @doc "Paginated list of running root PIs for resume-on-startup."
  @impl true
  def list_running_process_instances(opts) do
    limit = Keyword.fetch!(opts, :limit)
    cursor = Keyword.get(opts, :after)

    query =
      ProcessInstance
      |> Ash.Query.filter(state == ^@state_running and is_nil(parent_process_instance_id))
      |> Ash.Query.sort(id: :asc)
      |> Ash.Query.limit(limit)

    query =
      case cursor do
        nil -> query
        last_id -> Ash.Query.filter(query, id > ^last_id)
      end

    case Ash.read(query, domain: @domain, authorize?: false) do
      {:ok, records} ->
        {:ok,
         %{
           records: Enum.map(records, &process_instance_to_resume_map/1),
           next_cursor: compute_next_cursor(records, limit)
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "List FNIs for a PI that are relevant for resume (active, waiting, or finished end events)."
  @impl true
  def list_flow_node_instances(process_instance_id) do
    query =
      FlowNodeInstance
      |> Ash.Query.filter(
        process_instance_id == ^process_instance_id and
          (state in ^[@state_active, @state_waiting] or
             (state == ^@state_finished and flow_node_type == ^@flow_node_type_end_event))
      )

    case Ash.read(query, domain: @domain, authorize?: false) do
      {:ok, records} ->
        {:ok, Enum.map(records, &flow_node_instance_to_resume_map/1)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp process_instance_to_resume_map(record) do
    %{
      id: record.id,
      process_version_id: record.process_version_id,
      parent_process_instance_id: record.parent_process_instance_id,
      business_key: record.business_key,
      triggerer_flow_node_instance_id: record.triggerer_flow_node_instance_id,
      started_at: record.started_at,
      started_by: record.started_by,
      started_with_context: record.started_with_context
    }
  end

  defp flow_node_instance_to_resume_map(record) do
    %{
      id: record.id,
      flow_node_id: record.flow_node_id,
      flow_node_type: record.flow_node_type,
      event_type: record.event_type,
      state: record.state,
      input_token: record.input_token,
      output_token: record.output_token,
      type_properties: record.type_properties,
      previous_flow_node_instance_ids: record.previous_flow_node_instance_ids,
      lane_name: record.lane_name,
      started_at: record.started_at
    }
  end

  @doc "Finish an FNI and persist all Data Object writes in a single transaction."
  @impl true
  def finish_fni_with_data_objects(flow_node_instance_id, fni_changes, write_intents) do
    Repo.transaction(fn ->
      with {:ok, record} <-
             Ash.get(FlowNodeInstance, flow_node_instance_id, domain: @domain, authorize?: false),
           {:ok, _updated, notifications} <-
             Ash.update(record, fni_changes,
               domain: @domain,
               action: :update_finished,
               authorize?: false,
               return_notifications?: true
             ) do
        writes = Enum.map(write_intents, &persist_single_do_write/1)
        {%{writes: writes}, notifications}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, {result, notifications}} ->
        _notified = Ash.Notifier.notify(notifications)
        {:ok, result}

      {:error, _reason} = error ->
        error
    end
  end

  defp persist_single_do_write(intent) do
    now = DateTime.utc_now()
    write_id = Ash.UUIDv7.generate()

    upsert_sql = """
    INSERT INTO data_objects (id, process_instance_id, data_object_id,
                              flow_node_instance_id, value, created_at)
    VALUES ($1, $2, $3, $4, $5, $6)
    ON CONFLICT (process_instance_id, data_object_id)
    DO UPDATE SET id = EXCLUDED.id,
                  flow_node_instance_id = EXCLUDED.flow_node_instance_id,
                  value = EXCLUDED.value,
                  created_at = EXCLUDED.created_at
    """

    snapshot_id = dump_uuid!(Ash.UUIDv7.generate())
    process_instance_id_bin = dump_uuid!(intent.process_instance_id)
    flow_node_instance_id_bin = dump_uuid!(intent.flow_node_instance_id)

    _upsert_result =
      EctoSQL.query!(Repo, upsert_sql, [
        snapshot_id,
        process_instance_id_bin,
        intent.data_object_id,
        flow_node_instance_id_bin,
        intent.value,
        now
      ])

    audit_sql = """
    INSERT INTO data_object_writes (id, process_instance_id, data_object_id,
                                    flow_node_instance_id, value, created_at)
    VALUES ($1, $2, $3, $4, $5, $6)
    """

    _audit_result =
      EctoSQL.query!(Repo, audit_sql, [
        dump_uuid!(write_id),
        process_instance_id_bin,
        intent.data_object_id,
        flow_node_instance_id_bin,
        intent.value,
        now
      ])

    %{write_id: write_id, created_at: now}
  end

  @doc "Write a single Data Object snapshot + audit row in a transaction."
  @impl true
  def write_data_object(params) do
    now = DateTime.utc_now()
    write_id = Ash.UUIDv7.generate()

    Repo.transaction(fn ->
      upsert_sql = """
      INSERT INTO data_objects (id, process_instance_id, data_object_id,
                                flow_node_instance_id, value, created_at)
      VALUES ($1, $2, $3, $4, $5, $6)
      ON CONFLICT (process_instance_id, data_object_id)
      DO UPDATE SET id = EXCLUDED.id,
                    flow_node_instance_id = EXCLUDED.flow_node_instance_id,
                    value = EXCLUDED.value,
                    created_at = EXCLUDED.created_at
      """

      snapshot_id = dump_uuid!(Ash.UUIDv7.generate())
      process_instance_id_bin = dump_uuid!(params.process_instance_id)
      flow_node_instance_id_bin = dump_uuid!(params.flow_node_instance_id)

      _upsert_result =
        EctoSQL.query!(Repo, upsert_sql, [
          snapshot_id,
          process_instance_id_bin,
          params.data_object_id,
          flow_node_instance_id_bin,
          params.value,
          now
        ])

      audit_sql = """
      INSERT INTO data_object_writes (id, process_instance_id, data_object_id,
                                      flow_node_instance_id, value, created_at)
      VALUES ($1, $2, $3, $4, $5, $6)
      """

      _audit_result =
        EctoSQL.query!(Repo, audit_sql, [
          dump_uuid!(write_id),
          process_instance_id_bin,
          params.data_object_id,
          flow_node_instance_id_bin,
          params.value,
          now
        ])

      %{write_id: write_id, created_at: now}
    end)
  end

  @doc "Load the current Data Object values for a process instance (for resume cache)."
  @impl true
  def list_data_objects(process_instance_id) do
    case DataObjectResource
         |> Ash.Query.filter(process_instance_id == ^process_instance_id)
         |> Ash.read(domain: @domain, authorize?: false) do
      {:ok, records} ->
        {:ok,
         Enum.map(records, fn record ->
           %{data_object_id: record.data_object_id, value: record.value}
         end)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Load raw BPMN XML for a process version by its ID.

  Used as the `model_cache_loader` callback for `ModelCache`.
  Returns `{:ok, xml}` or `{:error, :not_found}`.
  """
  @spec load_bpmn_xml(String.t()) :: {:ok, String.t()} | {:error, :not_found}
  def load_bpmn_xml(process_version_id) do
    case Ash.get(ProcessVersion, process_version_id, domain: @domain, authorize?: false) do
      {:ok, %{bpmn_xml: xml}} when is_binary(xml) -> {:ok, xml}
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Load raw DMN XML for a decision version by its ID.

  Used as the `model_cache_loader` callback for `DMN.ModelCache`.
  Returns `{:ok, xml}` or `{:error, :not_found}`.
  """
  @spec load_dmn_xml(String.t()) :: {:ok, String.t()} | {:error, :not_found}
  def load_dmn_xml(decision_version_id) do
    case Ash.get(DecisionVersion, decision_version_id, domain: @domain, authorize?: false) do
      {:ok, %{dmn_xml: xml}} when is_binary(xml) -> {:ok, xml}
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Boot-time sweep: abort all FNIs stuck in non-terminal state on terminal PIs.
  Uses raw SQL for a single bulk UPDATE.
  """
  @impl true
  def cleanup_orphaned_flow_node_instances do
    sql = """
    UPDATE flow_node_instances
    SET state = 'aborted',
        finished_at = NOW(),
        error_info = '{"error_code":"orphaned_fni_cleanup","message":"FNI was in non-terminal state on a terminal PI and was cleaned up at engine startup"}'::jsonb
    WHERE state IN ('active', 'waiting')
      AND deleted = false
      AND process_instance_id IN (
        SELECT id FROM process_instances
        WHERE state IN ('finished', 'fatal', 'aborted', 'error', 'escalated')
          AND deleted = false
      )
    """

    case EctoSQL.query(Repo, sql) do
      {:ok, %{num_rows: count}} -> {:ok, count}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Boot-time sweep: abort orphaned child PIs whose parent is terminal.
  Iterates to handle nested orphans (grandchild, great-grandchild, etc.).
  Each pass also aborts the orphaned PIs' own FNIs.
  """
  @impl true
  def cleanup_orphaned_process_instances do
    cleanup_orphaned_process_instances_loop(0, 0)
  end

  @max_orphan_cleanup_passes 10

  defp cleanup_orphaned_process_instances_loop(pass, total_count)
       when pass >= @max_orphan_cleanup_passes do
    {:ok, total_count}
  end

  defp cleanup_orphaned_process_instances_loop(pass, total_count) do
    find_sql = """
    SELECT id FROM process_instances
    WHERE state = 'running'
      AND deleted = false
      AND parent_process_instance_id IS NOT NULL
      AND parent_process_instance_id IN (
        SELECT id FROM process_instances
        WHERE state IN ('finished', 'fatal', 'aborted', 'error', 'escalated')
          AND deleted = false
      )
    """

    case EctoSQL.query(Repo, find_sql) do
      {:ok, %{rows: []}} ->
        {:ok, total_count}

      {:ok, %{rows: rows}} ->
        orphaned_ids = Enum.map(rows, fn [id] -> id end)
        abort_orphaned_batch(orphaned_ids, pass, total_count)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp abort_orphaned_batch(orphaned_ids, pass, total_count) do
    abort_fnis_sql = """
    UPDATE flow_node_instances
    SET state = 'aborted',
        finished_at = NOW(),
        error_info = '{"error_code":"orphaned_fni_cleanup","message":"FNI was in non-terminal state on a terminal PI and was cleaned up at engine startup"}'::jsonb
    WHERE state IN ('active', 'waiting')
      AND deleted = false
      AND process_instance_id = ANY($1)
    """

    abort_pis_sql = """
    UPDATE process_instances
    SET state = 'aborted',
        finished_at = NOW(),
        error_info = '{"error_code":"orphaned_pi_cleanup","message":"Child PI had no active parent and was cleaned up at engine startup"}'::jsonb
    WHERE id = ANY($1)
      AND deleted = false
    """

    with {:ok, _fni_result} <- EctoSQL.query(Repo, abort_fnis_sql, [orphaned_ids]),
         {:ok, _pi_result} <- EctoSQL.query(Repo, abort_pis_sql, [orphaned_ids]) do
      cleanup_orphaned_process_instances_loop(pass + 1, total_count + length(orphaned_ids))
    end
  end

  # ---------------------------------------------------------------------------
  # Retry/restart callbacks
  # ---------------------------------------------------------------------------

  @doc "Read a PI by ID for retry validation. Returns full row data."
  @impl true
  def get_process_instance_for_retry(process_instance_id) do
    case Ash.get(ProcessInstance, process_instance_id, domain: @domain, authorize?: false) do
      {:ok, record} -> {:ok, process_instance_to_retry_map(record)}
      {:error, %Ash.Error.Query.NotFound{}} -> {:error, :not_found}
      {:error, _reason} -> {:error, :not_found}
    end
  end

  @doc "Read ALL FNIs for a PI (all states). Used for retry preparation."
  @impl true
  def list_all_flow_node_instances(process_instance_id) do
    query =
      FlowNodeInstance
      |> Ash.Query.filter(process_instance_id == ^process_instance_id)

    case Ash.read(query, domain: @domain, authorize?: false) do
      {:ok, records} ->
        {:ok, Enum.map(records, &flow_node_instance_to_retry_map/1)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Count ALL FNIs for a PI (all states). Lightweight alternative to list_all_flow_node_instances."
  @impl true
  def count_all_flow_node_instances(process_instance_id) do
    count_sql = """
    SELECT COUNT(*) FROM flow_node_instances
    WHERE process_instance_id = $1 AND deleted = false
    """

    case EctoSQL.query(Repo, count_sql, [dump_uuid!(process_instance_id)]) do
      {:ok, %{rows: [[count]]}} -> {:ok, count}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Fetch a single FNI by its own ID (for retry ancestor-chain inspection)."
  @impl true
  def get_flow_node_instance_by_id(fni_id) do
    case Ash.get(FlowNodeInstance, fni_id, domain: @domain, authorize?: false) do
      {:ok, record} -> {:ok, flow_node_instance_to_retry_map(record)}
      {:error, %Ash.Error.Query.NotFound{}} -> {:error, :not_found}
      {:error, _reason} -> {:error, :not_found}
    end
  end

  @doc "List direct child PIs by parent_process_instance_id (authoritative)."
  @impl true
  def list_child_process_instances(parent_process_instance_id) do
    query =
      ProcessInstance
      |> Ash.Query.filter(parent_process_instance_id == ^parent_process_instance_id)

    case Ash.read(query, domain: @domain, authorize?: false) do
      {:ok, records} ->
        {:ok,
         Enum.map(records, fn record ->
           %{
             id: record.id,
             state: record.state,
             triggerer_flow_node_instance_id: record.triggerer_flow_node_instance_id
           }
         end)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Merge a patch into a single FNI's type_properties."
  @impl true
  def patch_fni_type_properties(flow_node_instance_id, patch) do
    with {:ok, record} <-
           Ash.get(FlowNodeInstance, flow_node_instance_id, domain: @domain, authorize?: false) do
      merged = Map.merge(record.type_properties || %{}, patch)

      case Ash.update(
             record,
             %{type_properties: merged},
             domain: @domain,
             action: :retry_reset,
             authorize?: false
           ) do
        {:ok, _updated} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc "Atomically prepare a PI for retry within a single transaction."
  @impl true
  def execute_retry_reset(process_instance_id, opts) do
    Repo.transaction(fn ->
      with :ok <- maybe_delete_fnis(process_instance_id, opts),
           :ok <- reset_fnis(opts),
           :ok <- reset_process_instance(process_instance_id, opts),
           {:ok, reactivation_fnis} <- load_reactivation_fnis(process_instance_id) do
        reactivation_fnis
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc "Revert a failed retry: set PI back to its original terminal state."
  @impl true
  def revert_retry(process_instance_id, original_state, original_finished_at) do
    with {:ok, record} <-
           Ash.get(ProcessInstance, process_instance_id, domain: @domain, authorize?: false),
         {:ok, _updated} <-
           Ash.update(
             record,
             %{state: original_state, finished_at: original_finished_at},
             domain: @domain,
             action: :revert_retry,
             authorize?: false
           ) do
      :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Gateway pending arrival callbacks
  # ---------------------------------------------------------------------------

  @doc "Persist a branch arrival at a parallel/inclusive gateway join."
  @impl true
  def create_gateway_pending_arrival(params) do
    case Ash.create(GatewayPendingArrival, params, domain: @domain, authorize?: false) do
      {:ok, record} ->
        {:ok,
         %{
           id: record.id,
           process_instance_id: record.process_instance_id,
           gateway_flow_node_instance_id: record.gateway_flow_node_instance_id,
           source_branch_sequence_flow_id: record.source_branch_sequence_flow_id,
           source_flow_node_instance_id: record.source_flow_node_instance_id,
           arrived_payload: record.arrived_payload,
           arrived_at: record.arrived_at
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "List all pending arrivals for a process instance (used for resume)."
  @impl true
  def list_gateway_pending_arrivals(process_instance_id) do
    query =
      GatewayPendingArrival
      |> Ash.Query.filter(process_instance_id == ^process_instance_id)
      |> Ash.Query.sort(arrived_at: :asc)

    case Ash.read(query, domain: @domain, authorize?: false) do
      {:ok, records} ->
        {:ok,
         Enum.map(records, fn record ->
           %{
             id: record.id,
             process_instance_id: record.process_instance_id,
             gateway_flow_node_instance_id: record.gateway_flow_node_instance_id,
             source_branch_sequence_flow_id: record.source_branch_sequence_flow_id,
             source_flow_node_instance_id: record.source_flow_node_instance_id,
             arrived_payload: record.arrived_payload,
             arrived_at: record.arrived_at
           }
         end)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Delete all pending arrival rows for a specific gateway FNI."
  @impl true
  def delete_gateway_pending_arrivals_for_gateway(gateway_flow_node_instance_id) do
    gateway_fni_id_bin = dump_uuid!(gateway_flow_node_instance_id)

    delete_sql = """
    DELETE FROM gateway_pending_arrivals
    WHERE gateway_flow_node_instance_id = $1
    """

    case EctoSQL.query(Repo, delete_sql, [gateway_fni_id_bin]) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # execute_retry_reset helpers
  # ---------------------------------------------------------------------------

  defp maybe_delete_fnis(process_instance_id, %{delete_fni_ids: delete_fni_ids})
       when is_list(delete_fni_ids) and delete_fni_ids != [] do
    fni_ids = Enum.map(delete_fni_ids, &elem(&1, 0))

    cascade_delete_call_activity_children(delete_fni_ids)
    |> case do
      :ok -> rollback_data_objects(process_instance_id, fni_ids)
      error -> error
    end
    |> case do
      :ok -> bulk_delete_fnis(fni_ids)
      error -> error
    end
  end

  defp maybe_delete_fnis(_process_instance_id, _opts), do: :ok

  defp cascade_delete_call_activity_children(delete_fni_ids) do
    call_activity_children =
      delete_fni_ids
      |> Enum.filter(fn {_fni_id, flow_node_type, type_properties} ->
        flow_node_type in ["call_activity", "sub_process"] and
          is_binary(Map.get(type_properties || %{}, "child_process_instance_id"))
      end)
      |> Enum.map(fn {_id, _type, type_properties} ->
        type_properties["child_process_instance_id"]
      end)

    Enum.reduce_while(call_activity_children, :ok, fn child_pi_id, :ok ->
      case ProcessInstancePurge.hard_delete_process_instance_tree(child_pi_id) do
        :ok ->
          {:cont, :ok}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp rollback_data_objects(process_instance_id, fni_ids) do
    process_instance_id_bin = dump_uuid!(process_instance_id)
    fni_id_bins = Enum.map(fni_ids, &dump_uuid!/1)

    delete_writes_sql = """
    DELETE FROM data_object_writes
    WHERE process_instance_id = $1
      AND flow_node_instance_id = ANY($2)
    RETURNING data_object_id
    """

    case EctoSQL.query(Repo, delete_writes_sql, [process_instance_id_bin, fni_id_bins]) do
      {:ok, %{rows: []}} ->
        :ok

      {:ok, %{rows: affected_rows}} ->
        affected_data_object_ids =
          affected_rows
          |> Enum.map(fn [data_object_id] -> data_object_id end)
          |> Enum.uniq()

        reconcile_data_object_snapshots(process_instance_id_bin, affected_data_object_ids)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reconcile_data_object_snapshots(process_instance_id_bin, data_object_ids) do
    Enum.reduce_while(data_object_ids, :ok, fn data_object_id, :ok ->
      case reconcile_single_data_object(process_instance_id_bin, data_object_id) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp reconcile_single_data_object(process_instance_id_bin, data_object_id) do
    latest_write_sql = """
    SELECT value FROM data_object_writes
    WHERE process_instance_id = $1 AND data_object_id = $2
    ORDER BY created_at DESC
    LIMIT 1
    """

    case EctoSQL.query(Repo, latest_write_sql, [process_instance_id_bin, data_object_id]) do
      {:ok, %{rows: [[value]]}} ->
        update_data_object_snapshot(process_instance_id_bin, data_object_id, value)

      {:ok, %{rows: []}} ->
        delete_data_object_snapshot(process_instance_id_bin, data_object_id)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp update_data_object_snapshot(process_instance_id_bin, data_object_id, value) do
    upsert_sql = """
    UPDATE data_objects SET value = $1
    WHERE process_instance_id = $2 AND data_object_id = $3
    """

    case EctoSQL.query(Repo, upsert_sql, [value, process_instance_id_bin, data_object_id]) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp delete_data_object_snapshot(process_instance_id_bin, data_object_id) do
    delete_snapshot_sql = """
    DELETE FROM data_objects
    WHERE process_instance_id = $1 AND data_object_id = $2
    """

    case EctoSQL.query(Repo, delete_snapshot_sql, [process_instance_id_bin, data_object_id]) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp bulk_delete_fnis(fni_ids) do
    fni_id_bins = Enum.map(fni_ids, &dump_uuid!/1)

    delete_pending_arrivals_sql = """
    DELETE FROM gateway_pending_arrivals WHERE gateway_flow_node_instance_id = ANY($1)
    """

    delete_sql = """
    DELETE FROM flow_node_instances WHERE id = ANY($1)
    """

    with {:ok, _result} <- EctoSQL.query(Repo, delete_pending_arrivals_sql, [fni_id_bins]),
         {:ok, _result} <- EctoSQL.query(Repo, delete_sql, [fni_id_bins]) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp reset_fnis(%{reset_fni_ids: reset_fni_ids}) when is_list(reset_fni_ids) do
    Enum.reduce_while(reset_fni_ids, :ok, fn {fni_id, target_state}, :ok ->
      with {:ok, record} <-
             Ash.get(FlowNodeInstance, fni_id, domain: @domain, authorize?: false),
           {:ok, _updated} <-
             Ash.update(
               record,
               %{
                 state: target_state,
                 finished_at: nil,
                 error_info: nil,
                 output_token: nil,
                 type_properties: structural_type_properties(record)
               },
               domain: @domain,
               action: :retry_reset,
               authorize?: false
             ) do
        {:cont, :ok}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp reset_fnis(_opts), do: :ok

  defp structural_type_properties(%{flow_node_type: "boundary_event", type_properties: props})
       when is_map(props) do
    host_id =
      Map.get(props, "host_flow_node_instance_id") ||
        Map.get(props, :host_flow_node_instance_id)

    if host_id, do: %{"host_flow_node_instance_id" => host_id}, else: %{}
  end

  defp structural_type_properties(%{flow_node_type: flow_node_type, type_properties: props})
       when flow_node_type in ["call_activity", "sub_process"] and is_map(props) do
    child_id =
      Map.get(props, "child_process_instance_id") ||
        Map.get(props, :child_process_instance_id)

    if child_id, do: %{"child_process_instance_id" => child_id}, else: %{}
  end

  defp structural_type_properties(_record), do: %{}

  defp reset_process_instance(process_instance_id, opts) do
    changes =
      %{state: @state_running, finished_at: nil, error_info: nil}
      |> maybe_put_version_id(opts)

    with {:ok, record} <-
           Ash.get(ProcessInstance, process_instance_id, domain: @domain, authorize?: false),
         {:ok, _updated} <-
           Ash.update(record, changes,
             domain: @domain,
             action: :retry_reset,
             authorize?: false
           ) do
      :ok
    end
  end

  defp maybe_put_version_id(changes, %{version_id: version_id}) when is_binary(version_id) do
    Map.put(changes, :process_version_id, version_id)
  end

  defp maybe_put_version_id(changes, _opts), do: changes

  defp load_reactivation_fnis(process_instance_id) do
    query =
      FlowNodeInstance
      |> Ash.Query.filter(
        process_instance_id == ^process_instance_id and
          state in ^[@state_active, @state_waiting]
      )

    case Ash.read(query, domain: @domain, authorize?: false) do
      {:ok, records} ->
        {:ok, Enum.map(records, &flow_node_instance_to_retry_map/1)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Retry map helpers
  # ---------------------------------------------------------------------------

  defp process_instance_to_retry_map(record) do
    %{
      id: record.id,
      state: record.state,
      finished_at: record.finished_at,
      process_version_id: record.process_version_id,
      parent_process_instance_id: record.parent_process_instance_id,
      started_by: record.started_by,
      started_at: record.started_at,
      started_with_context: record.started_with_context,
      business_key: record.business_key,
      triggerer_flow_node_instance_id: record.triggerer_flow_node_instance_id,
      error_info: record.error_info
    }
  end

  defp flow_node_instance_to_retry_map(record) do
    %{
      id: record.id,
      flow_node_id: record.flow_node_id,
      flow_node_type: record.flow_node_type,
      event_type: record.event_type,
      state: record.state,
      started_at: record.started_at,
      input_token: record.input_token,
      output_token: record.output_token,
      type_properties: record.type_properties || %{},
      previous_flow_node_instance_ids: record.previous_flow_node_instance_ids || [],
      lane_name: record.lane_name,
      error_info: record.error_info
    }
  end

  # ---------------------------------------------------------------------------
  # Shared helpers
  # ---------------------------------------------------------------------------

  defp compute_next_cursor(records, limit) do
    if length(records) == limit do
      records |> List.last() |> Map.get(:id)
    else
      nil
    end
  end

  defp dump_uuid!(uuid_string) do
    {:ok, bin} = Ecto.UUID.dump(uuid_string)
    bin
  end
end
