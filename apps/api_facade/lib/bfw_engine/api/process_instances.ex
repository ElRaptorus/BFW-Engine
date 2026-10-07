defmodule BfwEngine.Api.ProcessInstances do
  @moduledoc """
  Process instance lifecycle.
  Callers use `BfwEngine.Api`.
  """

  require Ash.Query

  alias BfwEngine.Api.Validation
  alias BfwEngine.BPMN.ModelCache
  alias BfwEngine.Execution
  alias BfwEngine.Execution.CalledElementResolver
  alias BfwEngine.Execution.Persistence
  alias BfwEngine.Execution.PersistenceRetry
  alias BfwEngine.Persistence.Repo
  alias BfwEngine.Persistence.Resources

  @domain BfwEngine.Persistence.Api
  @non_terminal_states ~w(running suspended)

  @doc "Check whether any non-terminal PIs exist for a single process version."
  @spec has_active_process_instances?(binary()) :: boolean()
  def has_active_process_instances?(process_version_id) do
    Resources.ProcessInstance
    |> Ash.Query.filter(
      process_version_id == ^process_version_id and state in ^@non_terminal_states
    )
    |> Ash.Query.limit(1)
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, [_ | _]} -> true
      _ -> false
    end
  end

  @doc "Check whether any non-terminal PIs exist across a list of version IDs."
  @spec any_active_process_instances?([binary()]) :: boolean()
  def any_active_process_instances?(version_ids) do
    Resources.ProcessInstance
    |> Ash.Query.filter(process_version_id in ^version_ids and state in ^@non_terminal_states)
    |> Ash.Query.limit(1)
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, [_ | _]} -> true
      _ -> false
    end
  end

  @doc "Get a process instance by ID."
  @spec get_process_instance(binary()) :: {:ok, struct()} | {:error, term()}
  def get_process_instance(process_instance_id) do
    Resources.ProcessInstance
    |> Ash.get(process_instance_id, domain: @domain, authorize?: false)
    |> normalize_not_found()
  end

  @doc "Get a flow node instance by ID."
  @spec get_flow_node_instance(binary()) :: {:ok, struct()} | {:error, term()}
  def get_flow_node_instance(flow_node_instance_id) do
    Resources.FlowNodeInstance
    |> Ash.get(flow_node_instance_id, domain: @domain, authorize?: false)
    |> normalize_not_found()
  end

  @doc "List all flow node instances belonging to a process instance, ordered by start time."
  @spec list_flow_node_instances_for_process(binary()) :: {:ok, [struct()]} | {:error, term()}
  def list_flow_node_instances_for_process(process_instance_id) do
    Resources.FlowNodeInstance
    |> Ash.Query.filter(process_instance_id == ^process_instance_id)
    |> Ash.Query.sort(started_at: :asc)
    |> Ash.read(domain: @domain, authorize?: false)
  end

  @doc """
  Check lane-based access: returns `true` if the process instance has at
  least one FNI with a nil lane or a lane in `lane_names`.
  """
  @spec check_lane_access(binary(), [String.t()]) :: boolean()
  def check_lane_access(process_instance_id, lane_names) do
    Resources.FlowNodeInstance
    |> Ash.Query.filter(process_instance_id == ^process_instance_id)
    |> Ash.Query.filter(is_nil(lane_name) or lane_name in ^lane_names)
    |> Ash.Query.limit(1)
    |> Ash.read(domain: @domain, authorize?: false)
    |> case do
      {:ok, [_ | _]} -> true
      _ -> false
    end
  end

  @doc """
  Soft-delete a process instance and all its flow node instances in a
  single transaction.
  """
  @spec soft_delete_process_instance_with_fnis(struct(), map()) ::
          {:ok, struct()} | {:error, term()}
  def soft_delete_process_instance_with_fnis(process_instance, identity) do
    now = DateTime.utc_now()
    delete_attributes = %{deleted: true, deleted_at: now, deleted_by: identity}

    Repo.transaction(fn ->
      {:ok, updated_pi} =
        process_instance
        |> Ash.Changeset.for_update(:soft_delete, delete_attributes)
        |> Ash.update(authorize?: false)

      bulk_result =
        Resources.FlowNodeInstance
        |> Ash.Query.filter(process_instance_id == ^process_instance.id)
        |> Ash.bulk_update(:soft_delete, delete_attributes,
          domain: @domain,
          authorize?: false,
          return_errors?: true
        )

      case bulk_result do
        %Ash.BulkResult{status: :success} ->
          updated_pi

        %Ash.BulkResult{status: status, errors: errors}
        when status in [:partial_success, :error] ->
          Repo.rollback({:fni_bulk_delete_failed, errors})
      end
    end)
  end

  @doc """
  Start a new process instance with the given options.

  Validates that the process is enabled and that the caller has lane
  access to the start event before delegating to Execution.
  """
  @spec start_process_instance(map(), struct() | nil, keyword()) ::
          {:ok, pid()}
          | {:error, term()}
          | {:error, :process_disabled}
          | {:error, :engine_at_capacity, map()}
          | {:error, :no_start_event | :ambiguous_start_event | :start_event_not_found,
             String.t()}
          | BfwEngine.Api.forbidden_error()
  def start_process_instance(opts, identity \\ nil, api_opts \\ []) do
    with :ok <- validate_process_enabled(opts[:process_version_id]),
         :ok <-
           check_start_lane(
             opts[:process_version_id],
             opts[:start_event_id],
             identity,
             api_opts
           ) do
      Execution.start_process_instance(opts)
    end
  end

  @doc """
  Abort a running process instance.

  Validates `abort_process_instance` scoped claim (none/own/all) with
  ownership check for `own`.
  """
  @spec abort_process_instance(String.t(), String.t() | nil, struct(), keyword()) ::
          :ok | {:error, term()} | BfwEngine.Api.forbidden_error()
  def abort_process_instance(process_instance_id, reason, identity, opts \\ []) do
    with {:ok, process_instance} <- get_process_instance(process_instance_id),
         :ok <-
           Validation.check_scoped_claim(
             identity,
             "abort_process_instance",
             get_in(process_instance.started_by, ["id"]),
             opts
           ) do
      Execution.abort_process_instance(process_instance_id, reason, identity)
    end
  end

  @doc """
  Delete (soft-delete) a terminal process instance and all its FNIs.

  Validates `delete_process_instance` scoped claim and terminal state.
  """
  @spec delete_process_instance(String.t(), struct(), keyword()) ::
          {:ok, struct()}
          | {:error, term()}
          | BfwEngine.Api.forbidden_error()
          | {:error, :process_instance_not_terminal, String.t()}
  def delete_process_instance(process_instance_id, identity, opts \\ []) do
    with {:ok, process_instance} <- get_process_instance(process_instance_id),
         :ok <-
           Validation.check_scoped_claim(
             identity,
             "delete_process_instance",
             get_in(process_instance.started_by, ["id"]),
             opts
           ),
         :ok <- validate_terminal_state(process_instance) do
      soft_delete_process_instance_with_fnis(process_instance, Map.from_struct(identity))
    end
  end

  # ===========================================================================
  # Retry
  # ===========================================================================

  @doc """
  Retry a terminal process instance.

  Validates `retry_process_instance` scoped claim, prerequisites on the
  targeted PI (existence, state, not running, version resolution) at the
  API layer, then delegates tree analysis and execution to Core via
  `Execution.retry_process_instance/1`.
  """
  @spec retry_process_instance(String.t(), map(), BfwEngine.Types.Identity.t(), keyword()) ::
          :ok
          | {:error, term()}
          | {:error, atom(), term()}
          | {:error, atom(), term(), term()}
          | BfwEngine.Api.forbidden_error()
  def retry_process_instance(process_instance_id, retry_opts, identity, opts \\ []) do
    persistence_adapter = Persistence.adapter()

    with {:ok, pi_data} <-
           PersistenceRetry.with_retry(
             fn -> persistence_adapter.get_process_instance_for_retry(process_instance_id) end,
             "Api: get PI for retry #{process_instance_id}",
             max_attempts: 3
           ),
         :ok <-
           Validation.check_scoped_claim(
             identity,
             "retry_process_instance",
             pi_data[:started_by_id] || get_in(pi_data, [:started_by, "id"]),
             opts
           ),
         :ok <- validate_retriable_state(pi_data),
         :ok <- validate_not_running(process_instance_id),
         {:ok, resolved_version_id} <- resolve_retry_version(pi_data, retry_opts) do
      Execution.retry_process_instance(
        pi_data: pi_data,
        resolved_version_id: resolved_version_id,
        identity: identity,
        reset_to_flow_node_instance_id: Map.get(retry_opts, "resetToFlowNodeInstanceId")
      )
    end
  end

  defp validate_retriable_state(%{state: state})
       when state in ["fatal", "aborted", "error"],
       do: :ok

  defp validate_retriable_state(%{state: state}) do
    {:error, :process_instance_not_retriable, state}
  end

  defp validate_not_running(process_instance_id) do
    case Execution.lookup_process_instance(process_instance_id) do
      {:ok, _pid} -> {:error, :process_instance_not_retriable, "running"}
      {:error, :not_found} -> :ok
    end
  end

  defp resolve_retry_version(pi_data, retry_opts) do
    resolver = CalledElementResolver.adapter()

    case Map.get(retry_opts, "version") do
      nil ->
        {:ok, pi_data.process_version_id}

      "latest" ->
        resolve_latest_version_for_retry(pi_data, resolver)

      version_string ->
        resolve_specific_version_for_retry(pi_data, version_string, resolver)
    end
  end

  defp resolve_latest_version_for_retry(pi_data, resolver) do
    case find_process_id_for_version(pi_data.process_version_id) do
      {:ok, process_id} ->
        case resolver.resolve_latest_version_for_process_id(process_id) do
          {:ok, resolved} -> {:ok, resolved.process_version_id}
          {:error, :process_not_found} -> {:error, :version_not_found, "latest"}
          {:error, :version_disabled} -> {:error, :version_disabled, "latest"}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_specific_version_for_retry(pi_data, version_string, resolver) do
    case find_process_model_id_for_version(pi_data.process_version_id) do
      {:ok, process_model_id} ->
        case resolver.resolve_specific_version(process_model_id, version_string) do
          {:ok, resolved} -> {:ok, resolved.process_version_id}
          {:error, :version_not_found} -> {:error, :version_not_found, version_string}
          {:error, :version_disabled} -> {:error, :version_disabled, version_string}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp find_process_id_for_version(process_version_id) do
    case Ash.get(Resources.ProcessVersion, process_version_id,
           domain: @domain,
           authorize?: false
         ) do
      {:ok, version} -> {:ok, version.process_id}
      {:error, _} -> {:error, :version_not_found}
    end
  end

  defp find_process_model_id_for_version(process_version_id) do
    case find_process_id_for_version(process_version_id) do
      {:ok, process_id} ->
        case Ash.get(Resources.Process, process_id, domain: @domain, authorize?: false) do
          {:ok, process} -> {:ok, process.process_model_id}
          {:error, _} -> {:error, :version_not_found}
        end

      error ->
        error
    end
  end

  @doc "Look up a running process instance by ID."
  defdelegate lookup_process_instance(process_instance_id), to: Execution

  @terminal_states ~w(finished fatal aborted error escalated compensated)

  defp validate_terminal_state(%{state: state}) when state in @terminal_states, do: :ok

  defp validate_terminal_state(%{state: state}),
    do: {:error, :process_instance_not_terminal, state}

  defp validate_process_enabled(nil), do: :ok

  defp validate_process_enabled(process_version_id) do
    case Ash.get(Resources.ProcessVersion, process_version_id,
           domain: @domain,
           authorize?: false
         ) do
      {:ok, version} ->
        case Ash.get(Resources.Process, version.process_id,
               domain: @domain,
               authorize?: false
             ) do
          {:ok, %{enabled: true}} -> :ok
          {:ok, _} -> {:error, :process_disabled}
          _ -> :ok
        end

      _ ->
        :ok
    end
  end

  # ===========================================================================
  # Private — BPMN helpers
  # ===========================================================================

  defp check_start_lane(_version_id, _start_event_id, nil, _opts), do: :ok

  defp check_start_lane(process_version_id, start_event_id, identity, opts) do
    if Keyword.get(opts, :skip_claims, false) or Validation.admin_override?(identity) do
      :ok
    else
      do_check_start_lane(process_version_id, start_event_id, identity)
    end
  end

  defp do_check_start_lane(process_version_id, start_event_id, identity) do
    with {:ok, definitions} <- ModelCache.fetch(process_version_id),
         {:ok, process} <- find_executable_process(definitions),
         {:ok, start_event} <- resolve_start_event(process, start_event_id),
         lane_name when not is_nil(lane_name) <- find_lane_for_element(process, start_event.id) do
      record = %{lane_name: lane_name}
      Validation.check_lane_access(record, identity, [])
    else
      nil -> :ok
      other -> other
    end
  end

  defp find_executable_process(definitions) do
    case Enum.find(definitions.processes, & &1.is_executable) do
      nil -> {:error, :no_executable_process}
      process -> {:ok, process}
    end
  end

  defp resolve_start_event(process, nil) do
    none_start_events =
      Enum.filter(process.flow_nodes, fn node ->
        node.type == :start_event and
          match?(%BfwEngine.BPMN.Model.EventDefinition.None{}, node.type_data.event_definition)
      end)

    case none_start_events do
      [] ->
        {:error, :no_start_event, "No None Start Event found"}

      [single] ->
        {:ok, single}

      starts ->
        ids = Enum.map_join(starts, ", ", & &1.id)
        {:error, :ambiguous_start_event, "Multiple None Start Events found: #{ids}"}
    end
  end

  defp resolve_start_event(process, start_event_id) do
    all_start_events =
      Enum.filter(process.flow_nodes, &(&1.type == :start_event))

    case Enum.find(all_start_events, &(&1.id == start_event_id)) do
      nil ->
        ids = Enum.map_join(all_start_events, ", ", & &1.id)

        {:error, :start_event_not_found,
         "Start event '#{start_event_id}' not found among: #{ids}"}

      found ->
        {:ok, found}
    end
  end

  defp find_lane_for_element(process, element_id) do
    process
    |> Map.get(:lanes, [])
    |> Enum.find(fn lane -> element_id in (lane.flow_node_refs || []) end)
    |> case do
      nil -> nil
      lane -> lane.name
    end
  end

  defp normalize_not_found({:ok, record}), do: {:ok, record}

  defp normalize_not_found({:error, %Ash.Error.Invalid{} = error}) do
    not_found_or_invalid_key =
      Enum.any?(error.errors, fn
        %Ash.Error.Query.NotFound{} -> true
        %Ash.Error.Invalid.InvalidPrimaryKey{} -> true
        _ -> false
      end)

    if not_found_or_invalid_key, do: {:error, :not_found}, else: {:error, error}
  end

  defp normalize_not_found(other), do: other
end
