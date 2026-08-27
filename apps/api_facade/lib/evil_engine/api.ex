defmodule EvilEngine.Api do
  @moduledoc """
  The single service-layer facade for ThomasTheDaemonEngine.

  Every wire adapter (REST, GraphQL, WebSocket) and every in-BEAM
  plugin converges on this module instead of calling Ash
  resources directly. This concentrates authorization, transaction
  boundaries, and cache wiring in one place.

  Functions in this module are grouped into:

  - **Catalog reads** — query processes, versions, and instances
  - **Catalog writes** — create/update/soft-delete catalog entries
  - **Transactional deploy** — atomic batch deploy with cache priming
  - **Runtime delegates** — pass-through to `EvilEngine.Execution`
  """

  require Ash.Query
  require Logger

  alias EvilEngine.Api.Validation
  alias EvilEngine.BPMN
  alias EvilEngine.BPMN.LinterGate
  alias EvilEngine.BPMN.ModelCache
  alias EvilEngine.DMN
  alias EvilEngine.Events.EngineEventBus
  alias EvilEngine.Events.MessagePublisher
  alias EvilEngine.Events.MessageSubscriptions
  alias EvilEngine.Events.SignalPublisher
  alias EvilEngine.Events.SignalSubscriptions
  alias EvilEngine.Execution
  alias EvilEngine.Execution.CalledElementResolver
  alias EvilEngine.Execution.Persistence
  alias EvilEngine.Execution.PersistenceRetry
  alias EvilEngine.Persistence.Repo

  @type forbidden_error :: {:error, :forbidden, map()}
  alias EvilEngine.Persistence.Resources
  alias EvilEngine.Timers.StartEventManager
  alias EvilEngine.Types.Event

  @domain EvilEngine.Persistence.Api
  @non_terminal_states ~w(running suspended)

  # ===========================================================================
  # Catalog reads
  # ===========================================================================

  @doc "List all processes. Accepts optional Ash read opts (e.g. `page:`)."
  @spec list_processes(keyword()) :: {:ok, list()} | {:error, term()}
  def list_processes(opts \\ []) do
    Resources.Process
    |> Ash.read(Keyword.merge([authorize?: false], opts))
  end

  @doc "Find processes whose `process_model_id` is in `model_ids`."
  @spec find_processes_by_model_ids([String.t()]) :: {:ok, list()} | {:error, term()}
  def find_processes_by_model_ids(model_ids) do
    Resources.Process
    |> Ash.Query.filter(process_model_id in ^model_ids)
    |> Ash.read(authorize?: false)
  end

  @doc "Find a single process by its `process_model_id`."
  @spec get_process_by_model_id(String.t()) :: {:ok, struct()} | :not_found
  def get_process_by_model_id(model_id) do
    case Resources.Process
         |> Ash.Query.filter(process_model_id == ^model_id)
         |> Ash.read(authorize?: false) do
      {:ok, [process | _]} -> {:ok, process}
      _ -> :not_found
    end
  end

  @doc "Return the latest non-deleted version for a process."
  @spec get_latest_process_version(binary()) :: {:ok, struct()} | {:error, :no_active_version}
  def get_latest_process_version(process_id) do
    case Resources.ProcessVersion
         |> Ash.Query.filter(process_id == ^process_id)
         |> Ash.Query.sort(deployed_at: :desc)
         |> Ash.Query.limit(1)
         |> Ash.read(authorize?: false) do
      {:ok, [version | _]} -> {:ok, version}
      _ -> {:error, :no_active_version}
    end
  end

  @doc "Find a specific version by process_id and version string."
  @spec find_process_version_by_key(binary(), String.t()) :: {:ok, struct()} | :not_found
  def find_process_version_by_key(process_id, version_string) do
    case Resources.ProcessVersion
         |> Ash.Query.filter(process_id == ^process_id and version == ^version_string)
         |> Ash.read(authorize?: false) do
      {:ok, [version | _]} -> {:ok, version}
      _ -> :not_found
    end
  end

  @doc "List all non-deleted versions for a process, sorted newest-first. Accepts optional opts."
  @spec list_process_versions_for_process(binary(), keyword()) :: list()
  def list_process_versions_for_process(process_id, opts \\ []) do
    query =
      Resources.ProcessVersion
      |> Ash.Query.filter(process_id == ^process_id)
      |> Ash.Query.sort(deployed_at: :desc)

    case Ash.read(query, Keyword.merge([authorize?: false], opts)) do
      {:ok, versions} -> versions
      _ -> []
    end
  end

  @doc """
  Bulk-fetch the latest version per process for a list of process IDs.
  Returns a map of `%{process_id => latest_version}`.
  """
  @spec find_latest_versions_by_process_ids([binary()]) :: %{optional(binary()) => struct()}
  def find_latest_versions_by_process_ids(process_ids) do
    case Resources.ProcessVersion
         |> Ash.Query.filter(process_id in ^process_ids)
         |> Ash.Query.sort(deployed_at: :desc)
         |> Ash.read(authorize?: false) do
      {:ok, versions} ->
        Enum.reduce(versions, %{}, fn v, acc -> Map.put_new(acc, v.process_id, v) end)

      _ ->
        %{}
    end
  end

  @doc "Fetch all non-deleted versions for the given process IDs."
  @spec find_process_versions_by_process_ids([binary()]) :: {:ok, list()} | {:error, term()}
  def find_process_versions_by_process_ids(process_ids) do
    Resources.ProcessVersion
    |> Ash.Query.filter(process_id in ^process_ids)
    |> Ash.read(authorize?: false)
  end

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

  # ===========================================================================
  # Catalog writes
  # ===========================================================================

  @doc """
  Find or create a Process record by `process_model_id`. If found and
  `is_executable` differs from the current `enabled` flag, sync it.
  """
  @spec create_or_sync_process!(String.t(), map()) :: struct()
  def create_or_sync_process!(process_model_id, definitions) do
    bpmn_process = Enum.find(definitions.processes, fn p -> p.id == process_model_id end)
    is_executable = if bpmn_process, do: bpmn_process.is_executable, else: true

    case get_process_by_model_id(process_model_id) do
      {:ok, process} ->
        sync_enabled(process, is_executable)

      :not_found ->
        name = if bpmn_process, do: bpmn_process.name

        {:ok, process} =
          Resources.Process
          |> Ash.Changeset.for_create(:create, %{
            process_model_id: process_model_id,
            name: name,
            enabled: is_executable,
            created_at: DateTime.utc_now()
          })
          |> Ash.create(authorize?: false)

        process
    end
  end

  @doc """
  Toggle the `enabled` flag on a Process.

  Validates the `deploy_bpmn` claim unless `skip_claims: true`.
  Accepts an optional `identity` for claim checking.
  """
  @spec update_process_enabled(struct(), boolean(), keyword()) ::
          {:ok, struct()} | {:error, term()} | forbidden_error()
  def update_process_enabled(process, enabled_value, opts \\ []) do
    identity = Keyword.get(opts, :identity)

    with :ok <- maybe_check_deploy_claim(identity, opts) do
      do_update_process_enabled(process, enabled_value, opts)
    end
  end

  defp maybe_check_deploy_claim(nil, _opts), do: :ok

  defp maybe_check_deploy_claim(identity, opts),
    do: Validation.check_claim(identity, "deploy_bpmn", opts)

  defp do_update_process_enabled(process, enabled_value, opts) do
    source = Keyword.get(opts, :source, "user:unknown")

    result =
      process
      |> Ash.Changeset.for_update(:update_enabled, %{enabled: enabled_value})
      |> Ash.update(authorize?: false)

    case result do
      {:ok, _updated} = success ->
        event_struct =
          if enabled_value do
            %Event.ProcessDefinitionEnabled{
              process_model_id: process.process_model_id,
              source: source,
              occurred_at: DateTime.utc_now()
            }
          else
            %Event.ProcessDefinitionDisabled{
              process_model_id: process.process_model_id,
              source: source,
              occurred_at: DateTime.utc_now()
            }
          end

        EngineEventBus.publish(event_struct)
        success

      error ->
        error
    end
  end

  @doc "Create a new ProcessVersion. Returns `{:error, :version_exists}` on duplicate."
  @spec create_process_version(map()) ::
          {:ok, struct()} | {:error, :version_exists} | {:error, term()}
  def create_process_version(attrs) do
    Resources.ProcessVersion
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create(authorize?: false)
    |> case do
      {:ok, version} ->
        {:ok, version}

      {:error, %Ash.Error.Invalid{errors: errors}} = error ->
        if Enum.any?(errors, &identity_violation?/1) do
          {:error, :version_exists}
        else
          error
        end

      error ->
        error
    end
  end

  defp identity_violation?(%{class: :invalid, field: :unique_process_version}), do: true

  defp identity_violation?(%Ash.Error.Changes.InvalidChanges{
         fields: fields,
         message: message
       })
       when is_list(fields) do
    Enum.any?(fields, &(&1 in [:process_id, :version])) or
      String.contains?(to_string(message), "unique")
  end

  defp identity_violation?(%{error: error}) when is_binary(error) do
    String.contains?(error, "unique_process_version") or
      String.contains?(error, "ConstraintError")
  end

  defp identity_violation?(_), do: false

  @doc "Soft-delete a ProcessVersion."
  @spec soft_delete_process_version(struct(), map(), keyword()) ::
          {:ok, struct()} | {:error, term()}
  def soft_delete_process_version(process_version, identity, opts \\ []) do
    source = Keyword.get(opts, :source, derive_source(identity))

    result =
      process_version
      |> Ash.Changeset.for_update(:soft_delete, %{
        deleted: true,
        deleted_at: DateTime.utc_now(),
        deleted_by: identity
      })
      |> Ash.update(authorize?: false)

    case result do
      {:ok, _deleted} = success ->
        StartEventManager.unregister_timer_starts(process_version.id)
        emit_process_undeployed(process_version, source)
        success

      error ->
        error
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

  # ===========================================================================
  # Transactional deploy
  # ===========================================================================

  @doc """
  Deploy a batch of BPMN definitions.

  Accepts pre-extracted BPMN entries (each `%{filename: String.t(), xml: String.t()}`),
  parses, validates, runs the linter gate, checks uniqueness, and persists.

  Validates the `deploy_bpmn` claim unless `skip_claims: true`.
  """
  @spec deploy_bpmn([map()], map(), keyword()) ::
          {:ok, [map()]}
          | {:error, :parse_error, list()}
          | {:error, :validation_failed, list()}
          | {:error, :linter_gate_failed, list()}
          | {:error, :batch_conflict, list()}
          | {:error, :version_exists, list()}
          | {:error, term()}
          | forbidden_error()
  def deploy_bpmn(bpmn_entries, deployer, opts \\ []) do
    with :ok <- Validation.check_claim(deployer, "deploy_bpmn", opts),
         {:ok, parsed_entries} <- parse_all_bpmn(bpmn_entries),
         :ok <- linter_gate_all(parsed_entries),
         {:ok, checked_entries} <- uniqueness_check_all(parsed_entries) do
      process_versions = extract_process_versions(checked_entries)
      do_persist_deploy_batch(process_versions, deployer, opts)
    end
  end

  @doc """
  Persist a batch of parsed BPMN process versions in a single transaction.
  Each entry in `process_versions` must have `:process_model_id`, `:version`,
  `:xml`, and `:definitions`. After the transaction, primes the ModelCache.

  Validates the `deploy_bpmn` claim unless `skip_claims: true` is passed.
  """
  @spec persist_deploy_batch([map()], map(), keyword()) ::
          {:ok, [map()]}
          | {:error, :version_exists, [map()]}
          | {:error, term()}
          | forbidden_error()
  def persist_deploy_batch(process_versions, deployer, opts \\ []) do
    with :ok <- Validation.check_claim(deployer, "deploy_bpmn", opts) do
      do_persist_deploy_batch(process_versions, deployer, opts)
    end
  end

  defp do_persist_deploy_batch(process_versions, deployer, opts) do
    source = Keyword.get(opts, :source, derive_source(deployer))

    tx_result =
      Repo.transaction(fn ->
        process_versions
        |> Enum.reduce_while([], &persist_single_version(&1, deployer, &2))
        |> Enum.reverse()
      end)

    unwrap_deploy_result(tx_result, source)
  end

  defp persist_single_version(process_version, deployer, accumulated) do
    process =
      create_or_sync_process!(process_version.process_model_id, process_version.definitions)

    version_attrs = %{
      process_id: process.id,
      version: process_version.version,
      definitions_id: process_version.definitions.definitions_id,
      bpmn_xml: process_version.xml,
      deployer: deployer,
      deployed_at: DateTime.utc_now()
    }

    case create_process_version(version_attrs) do
      {:ok, version} ->
        result = %{
          process_id: process.id,
          process_model_id: process.process_model_id,
          version_id: version.id,
          version: version.version,
          definitions: process_version.definitions
        }

        {:cont, [result | accumulated]}

      {:error, :version_exists} ->
        conflict = %{
          process_model_id: process_version.process_model_id,
          version: process_version.version
        }

        Repo.rollback({:version_exists, [conflict]})

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp unwrap_deploy_result({:ok, results}, source) do
    Enum.each(results, fn result ->
      ModelCache.put_new(result.version_id, result.definitions)

      register_timer_starts_for_version(
        result.version_id,
        result.process_model_id,
        result.definitions
      )

      EngineEventBus.publish(%Event.ProcessDefinitionDeployed{
        process_model_id: result.process_model_id,
        version: result.version,
        source: source,
        occurred_at: DateTime.utc_now()
      })
    end)

    {:ok, Enum.map(results, &Map.drop(&1, [:definitions, :process_id, :version_id]))}
  end

  defp unwrap_deploy_result({:error, {:version_exists, conflicts}}, _source) do
    {:error, :version_exists, conflicts}
  end

  defp unwrap_deploy_result(error, _source), do: error

  defp parse_all_bpmn(entries) do
    results =
      Enum.map(entries, fn entry ->
        case BPMN.parse_and_validate(entry.xml) do
          {:ok, definitions} -> {:ok, Map.put(entry, :definitions, definitions)}
          {:error, reason} -> {:error, entry.filename, reason}
        end
      end)

    failures =
      results
      |> Enum.filter(&match?({:error, _, _}, &1))
      |> Enum.map(fn {:error, filename, reason} ->
        %{file: filename, details: format_bpmn_parse_error(reason)}
      end)

    if failures == [] do
      successes = Enum.map(results, fn {:ok, entry} -> entry end)
      {:ok, successes}
    else
      error_type = categorize_bpmn_parse_failures(failures)
      {:error, error_type, failures}
    end
  end

  defp format_bpmn_parse_error(violations) when is_list(violations) do
    Enum.map(violations, &format_bpmn_violation/1)
  end

  defp format_bpmn_parse_error(%{
         exception: exception,
         element_id: element_id,
         element_type: element_type
       }) do
    base = format_bpmn_exception_message(exception)
    context = if element_id, do: " (element: #{element_type} '#{element_id}')", else: ""
    ["#{base}#{context}"]
  end

  defp format_bpmn_parse_error(%{__exception__: true} = exception) do
    [format_bpmn_exception_message(exception)]
  end

  defp format_bpmn_parse_error(reason) when is_binary(reason), do: [reason]

  defp format_bpmn_parse_error(reason) do
    Logger.error("Unrecognized parse error shape: #{inspect(reason)}")
    ["BPMN parsing failed. Server logs contain the full diagnostic."]
  end

  defp format_bpmn_exception_message(%FunctionClauseError{}) do
    "BPMN contains an unsupported construct that the parser could not process. " <>
      "Server logs contain the technical details."
  end

  defp format_bpmn_exception_message(%Saxy.ParseError{} = exception) do
    "Invalid XML syntax: #{Exception.message(exception)}"
  end

  defp format_bpmn_exception_message(_exception) do
    "BPMN parsing encountered an unexpected error. Server logs contain the technical details."
  end

  defp format_bpmn_violation({_code, message}) when is_binary(message), do: message
  defp format_bpmn_violation(value) when is_binary(value), do: value

  defp format_bpmn_violation(other) do
    Logger.warning("Unrecognized validation violation shape: #{inspect(other)}")
    "Validation issue detected. Server logs contain the technical details."
  end

  defp categorize_bpmn_parse_failures(failures) do
    has_validation =
      Enum.any?(failures, fn failure ->
        Enum.any?(failure.details, &String.contains?(&1, "is missing required"))
      end)

    if has_validation, do: :validation_failed, else: :parse_error
  end

  defp linter_gate_all(entries) do
    failures =
      Enum.flat_map(entries, fn entry ->
        case LinterGate.check(entry.definitions) do
          {:ok, :passed} -> []
          {:error, gate_failures} -> [%{file: entry.filename, ruleset_failures: gate_failures}]
        end
      end)

    if failures == [], do: :ok, else: {:error, :linter_gate_failed, failures}
  end

  defp uniqueness_check_all(entries) do
    process_versions = extract_process_versions(entries)

    case check_intra_batch_conflicts(process_versions) do
      {:error, conflicts} ->
        {:error, :batch_conflict, conflicts}

      :ok ->
        case check_db_conflicts(process_versions) do
          {:error, :version_exists, conflicts} ->
            {:error, :version_exists, conflicts}

          {:error, reason} ->
            {:error, {:internal_deploy_error, reason}}

          :ok ->
            {:ok, entries}
        end
    end
  end

  defp extract_process_versions(entries) do
    Enum.flat_map(entries, fn entry ->
      Enum.map(entry.definitions.processes, fn process ->
        %{
          process_model_id: process.id,
          version: process.version,
          filename: entry.filename,
          definitions: entry.definitions,
          xml: entry.xml
        }
      end)
    end)
  end

  defp check_intra_batch_conflicts(process_versions) do
    grouped =
      process_versions
      |> Enum.group_by(fn process_version ->
        {process_version.process_model_id, process_version.version}
      end)
      |> Enum.filter(fn {_key, entries} -> length(entries) > 1 end)

    if grouped == [] do
      :ok
    else
      conflicts =
        Enum.map(grouped, fn {{process_model_id, version}, entries} ->
          %{
            process_model_id: process_model_id,
            version: version,
            files: Enum.map(entries, & &1.filename)
          }
        end)

      {:error, conflicts}
    end
  end

  defp check_db_conflicts(process_versions) do
    model_ids = process_versions |> Enum.map(& &1.process_model_id) |> Enum.uniq()

    case find_processes_by_model_ids(model_ids) do
      {:ok, existing_processes} when existing_processes != [] ->
        do_check_db_conflicts(process_versions, existing_processes)

      _ ->
        :ok
    end
  end

  defp do_check_db_conflicts(process_versions, existing_processes) do
    process_id_by_key = Map.new(existing_processes, &{&1.process_model_id, &1.id})
    process_ids = Map.values(process_id_by_key)

    case fetch_existing_version_set(process_ids) do
      {:ok, existing_version_set} ->
        conflicts =
          process_versions
          |> Enum.filter(&version_conflict?(&1, process_id_by_key, existing_version_set))
          |> Enum.map(&%{process_model_id: &1.process_model_id, version: &1.version})

        if conflicts == [], do: :ok, else: {:error, :version_exists, conflicts}

      {:error, reason} ->
        {:error, {:fetch_versions_failed, reason}}
    end
  end

  @spec version_conflict?(map(), map(), %{optional({binary(), binary()}) => true}) :: boolean()
  defp version_conflict?(process_version, process_id_by_key, existing_version_set) do
    case Map.get(process_id_by_key, process_version.process_model_id) do
      nil -> false
      process_id -> Map.has_key?(existing_version_set, {process_id, process_version.version})
    end
  end

  defp register_timer_starts_for_version(version_id, process_model_id, definitions) do
    cycle_specs =
      definitions.processes
      |> Enum.filter(& &1.is_executable)
      |> Enum.flat_map(& &1.flow_nodes)
      |> Enum.filter(&timer_start_event?/1)
      |> Enum.map(&extract_timer_start_spec/1)
      |> Enum.filter(&(&1.kind == :cycle))

    unless Enum.empty?(cycle_specs) do
      StartEventManager.register_timer_starts(
        version_id,
        process_model_id,
        cycle_specs
      )
    end
  end

  defp timer_start_event?(%{type: :start_event, type_data: type_data}) do
    match?(
      %EvilEngine.BPMN.Model.EventDefinition.Timer{},
      type_data.event_definition
    )
  end

  defp timer_start_event?(_node), do: false

  defp extract_timer_start_spec(node) do
    event_def = node.type_data.event_definition

    {kind, iso_spec} =
      cond do
        is_binary(event_def.time_date) and event_def.time_date != "" ->
          {:date, event_def.time_date}

        is_binary(event_def.time_duration) and event_def.time_duration != "" ->
          {:duration, event_def.time_duration}

        is_binary(event_def.time_cycle) and event_def.time_cycle != "" ->
          {:cycle, event_def.time_cycle}
      end

    %{flow_node_id: node.id, kind: kind, iso_spec: iso_spec}
  end

  # ===========================================================================
  # Fetch existing version set (uniqueness check)
  # ===========================================================================

  @doc """
  Return a set (as a map) of `{process_id, version}` pairs for all
  non-deleted versions belonging to the given process IDs. Used by the
  deploy controller for pre-deploy uniqueness checks.
  """
  @spec fetch_existing_version_set([binary()]) ::
          {:ok, %{optional({binary(), binary()}) => true}} | {:error, term()}
  def fetch_existing_version_set(process_ids) do
    case Resources.ProcessVersion
         |> Ash.Query.filter(process_id in ^process_ids)
         |> Ash.read(authorize?: false) do
      {:ok, versions} ->
        {:ok, Map.new(versions, fn v -> {{v.process_id, v.version}, true} end)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ===========================================================================
  # Runtime — Process Instance lifecycle
  # ===========================================================================

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
          | forbidden_error()
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
          :ok | {:error, term()} | forbidden_error()
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
          | forbidden_error()
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
  @spec retry_process_instance(String.t(), map(), EvilEngine.Types.Identity.t(), keyword()) ::
          :ok
          | {:error, term()}
          | {:error, atom(), term()}
          | {:error, atom(), term(), term()}
          | forbidden_error()
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

  @doc """
  Complete a waiting User Task or Manual Task.

  Validates FNI existence, type (user_task/manual_task), waiting state,
  and lane access before delegating to Execution.
  """
  @spec finish_user_task(String.t(), term(), struct(), keyword()) ::
          :ok | {:error, term()} | {:error, :payload_too_large, map()} | forbidden_error()
  def finish_user_task(flow_node_instance_id, result, identity, opts \\ []) do
    with {:ok, flow_node_instance} <- get_flow_node_instance(flow_node_instance_id),
         :ok <- validate_user_task_type(flow_node_instance),
         :ok <- validate_fni_waiting(flow_node_instance),
         :ok <- Validation.check_lane_access(flow_node_instance, identity, opts) do
      Execution.finish_user_task(
        flow_node_instance.process_instance_id,
        flow_node_instance_id,
        result,
        identity
      )
    end
  end

  @doc """
  Cancel a waiting User Task or Manual Task.

  Validates FNI existence, type, waiting state, and lane access before
  delegating to Execution.
  """
  @spec cancel_user_task(String.t(), String.t() | nil, struct(), keyword()) ::
          :ok | {:error, term()} | forbidden_error()
  def cancel_user_task(flow_node_instance_id, reason, identity, opts \\ []) do
    with {:ok, flow_node_instance} <- get_flow_node_instance(flow_node_instance_id),
         :ok <- validate_user_task_type(flow_node_instance),
         :ok <- validate_fni_waiting(flow_node_instance),
         :ok <- Validation.check_lane_access(flow_node_instance, identity, opts) do
      Execution.cancel_user_task(
        flow_node_instance.process_instance_id,
        flow_node_instance_id,
        reason,
        identity
      )
    end
  end

  # ===========================================================================
  # Runtime — BPMN version delete + undeploy
  # ===========================================================================

  @doc """
  Delete (soft-delete) a specific BPMN process version.

  Validates `delete_bpmn` claim and that no active PIs exist on this version.
  """
  @spec delete_process_version(String.t(), String.t(), struct(), keyword()) ::
          {:ok, struct()}
          | {:error, :not_found}
          | {:error, :active_instances_exist}
          | {:error, term()}
          | forbidden_error()
  def delete_process_version(model_id, version_string, identity, opts \\ []) do
    with :ok <- Validation.check_claim(identity, "delete_bpmn", opts),
         {:ok, process} <- get_process_by_model_id(model_id),
         {:ok, process_version} <- find_process_version_by_key(process.id, version_string),
         false <- has_active_process_instances?(process_version.id) do
      soft_delete_process_version(process_version, identity, opts)
    else
      true -> {:error, :active_instances_exist}
      :not_found -> {:error, :not_found}
      other -> other
    end
  end

  @doc """
  Undeploy a process (soft-delete all versions).

  Validates `delete_bpmn` claim, no active PIs across all versions,
  and at least one active version.
  """
  @spec undeploy_process(String.t(), struct(), keyword()) ::
          :ok
          | {:error, :not_found}
          | {:error, :no_active_versions}
          | {:error, :active_instances_exist}
          | {:error, term()}
          | forbidden_error()
  def undeploy_process(model_id, identity, opts \\ []) do
    with :ok <- Validation.check_claim(identity, "delete_bpmn", opts),
         {:ok, process} <- get_process_by_model_id(model_id) do
      do_undeploy_versions(process.id, identity, opts)
    else
      :not_found -> {:error, :not_found}
      other -> other
    end
  end

  defp do_undeploy_versions(process_id, identity, opts) do
    active_versions = list_process_versions_for_process(process_id)

    cond do
      active_versions == [] ->
        {:error, :no_active_versions}

      any_active_process_instances?(Enum.map(active_versions, & &1.id)) ->
        {:error, :active_instances_exist}

      true ->
        results = Enum.map(active_versions, &soft_delete_process_version(&1, identity, opts))

        case Enum.find(results, &match?({:error, _}, &1)) do
          nil -> :ok
          error -> error
        end
    end
  end

  # ===========================================================================
  # Runtime — Message + Signal publishing
  # ===========================================================================

  @doc """
  Publish a message event.

  Validates `trigger_message` claim and subscription readiness before
  delegating to `MessagePublisher`.
  """
  @spec publish_message(String.t(), map(), String.t() | nil, struct(), keyword()) ::
          {:ok, map()} | {:error, :subscriptions_not_ready} | forbidden_error()
  def publish_message(message_name, payload, correlation, identity, opts \\ []) do
    with :ok <- check_message_subscriptions_ready(),
         :ok <- Validation.check_required_claim(identity, "trigger_message", "all", opts) do
      MessagePublisher.publish_message(%{
        name: message_name,
        payload: payload,
        correlation_value: correlation,
        origin: derive_origin(identity),
        skip_pending: Keyword.get(opts, :skip_pending, false)
      })
    end
  end

  @doc """
  Broadcast a signal event.

  Validates `trigger_signal` claim and subscription readiness before
  delegating to `SignalPublisher`.
  """
  @spec publish_signal(String.t(), struct(), keyword()) ::
          {:ok, map()} | {:error, :subscriptions_not_ready} | forbidden_error()
  def publish_signal(signal_name, identity, opts \\ []) do
    with :ok <- check_signal_subscriptions_ready(),
         :ok <- Validation.check_required_claim(identity, "trigger_signal", "all", opts) do
      SignalPublisher.publish_signal(%{
        name: signal_name,
        origin: derive_origin(identity),
        skip_pending: Keyword.get(opts, :skip_pending, false)
      })
    end
  end

  defp check_message_subscriptions_ready do
    if MessageSubscriptions.ready?(), do: :ok, else: {:error, :subscriptions_not_ready}
  end

  defp check_signal_subscriptions_ready do
    if SignalSubscriptions.ready?(), do: :ok, else: {:error, :subscriptions_not_ready}
  end

  # ===========================================================================
  # Runtime — Timer event manual trigger
  # ===========================================================================

  @doc """
  Manually trigger a waiting Timer Event FNI.

  Validates FNI existence, timer event type, active/waiting state,
  and lane access before delegating to Execution.
  """
  @spec trigger_timer_event(String.t(), struct(), keyword()) ::
          :ok | {:error, term()} | forbidden_error()
  def trigger_timer_event(flow_node_instance_id, identity, opts \\ []) do
    with {:ok, flow_node_instance} <- get_flow_node_instance(flow_node_instance_id),
         :ok <- validate_timer_event_type(flow_node_instance),
         :ok <- validate_fni_active_or_waiting(flow_node_instance),
         :ok <- Validation.check_lane_access(flow_node_instance, identity, opts) do
      Execution.trigger_timer_event(
        flow_node_instance.process_instance_id,
        flow_node_instance_id
      )
    end
  end

  @escalation_code_max_length 256

  @doc """
  Inject an escalation into waiting catchers on every running process instance.

  Validates the boolean `trigger_escalation` claim, then delegates to
  `Execution.trigger_escalation/2`. Escalations carry no payload.
  """
  @spec trigger_escalation(String.t(), struct(), keyword()) ::
          {:ok, map()}
          | {:error, :escalation_code_blank | :escalation_code_too_long}
          | forbidden_error()
  def trigger_escalation(escalation_code, identity, opts \\ []) do
    with {:ok, normalized_code} <- validate_escalation_code(escalation_code),
         :ok <- Validation.check_claim(identity, "trigger_escalation", opts) do
      {:ok, deliveries} = Execution.trigger_escalation(normalized_code, opts)

      {:ok,
       %{
         escalation_code: normalized_code,
         deliveries: deliveries,
         pending: false
       }}
    end
  end

  defp validate_escalation_code(escalation_code) when not is_binary(escalation_code) do
    {:error, :escalation_code_blank}
  end

  defp validate_escalation_code(escalation_code) do
    trimmed = String.trim(escalation_code)

    cond do
      trimmed == "" -> {:error, :escalation_code_blank}
      String.length(trimmed) > @escalation_code_max_length -> {:error, :escalation_code_too_long}
      true -> {:ok, trimmed}
    end
  end

  # ===========================================================================
  # Runtime — Timer start event schedules
  # ===========================================================================

  @doc """
  List Timer Start Event schedules.

  Requires `deploy_bpmn`. Filter opts (`:process_version_id`, `:enabled`)
  are forwarded to `StartEventManager.list_schedules/1`.
  """
  @spec list_timer_schedules(struct(), keyword()) ::
          {:ok, [map()]} | {:error, :forbidden, %{required_claim: term()}}
  def list_timer_schedules(identity, opts \\ []) do
    {claim_opts, filter_opts} = Keyword.split(opts, [:skip_claims])

    with :ok <- Validation.check_claim(identity, "deploy_bpmn", claim_opts) do
      StartEventManager.list_schedules(filter_opts)
    end
  end

  @doc "Get a single Timer Start Event schedule by id."
  @spec get_timer_schedule(String.t(), struct(), keyword()) ::
          {:ok, map()} | {:error, :not_found} | forbidden_error()
  def get_timer_schedule(schedule_id, identity, opts \\ []) do
    with :ok <- Validation.check_claim(identity, "deploy_bpmn", opts) do
      StartEventManager.get_schedule(schedule_id)
    end
  end

  @doc "Re-enable a disabled cycle Timer Start Event schedule."
  @spec enable_timer_schedule(String.t(), struct(), keyword()) ::
          {:ok, map()} | {:error, term()} | forbidden_error()
  def enable_timer_schedule(schedule_id, identity, opts \\ []) do
    with :ok <- Validation.check_claim(identity, "deploy_bpmn", opts) do
      StartEventManager.enable_schedule(schedule_id)
    end
  end

  @doc "Disable an enabled cycle Timer Start Event schedule."
  @spec disable_timer_schedule(String.t(), struct(), keyword()) ::
          {:ok, map()} | {:error, term()} | forbidden_error()
  def disable_timer_schedule(schedule_id, identity, opts \\ []) do
    with :ok <- Validation.check_claim(identity, "deploy_bpmn", opts) do
      StartEventManager.disable_schedule(schedule_id)
    end
  end

  # ===========================================================================
  # Runtime — Service Task + lookup delegates
  # ===========================================================================

  @doc "Complete a parked async Service Task with a result."
  defdelegate finish_async_service_task(flow_node_instance_id, result), to: Execution

  @doc "Fail a parked async Service Task with an error code and message."
  defdelegate fail_async_service_task(flow_node_instance_id, error_code, error_message),
    to: Execution

  @doc "Look up a running process instance by ID."
  defdelegate lookup_process_instance(process_instance_id), to: Execution

  # ===========================================================================
  # Runtime — Ad-hoc Subprocess
  # ===========================================================================

  @doc """
  Get the enabled/performed inner activities of an ad-hoc subprocess.

  `process_instance_id` is the **child** PI spawned by the ad-hoc subprocess
  handler — not the parent PI.
  """
  @spec get_adhoc_enabled_activities(String.t(), EvilEngine.Types.Identity.t(), keyword()) ::
          {:ok, [map()]} | {:error, term()} | forbidden_error()
  def get_adhoc_enabled_activities(process_instance_id, identity, opts \\ []) do
    with :ok <- Validation.check_claim(identity, "manage_adhoc_subprocess", opts) do
      Execution.get_adhoc_enabled_activities(process_instance_id)
    end
  end

  @doc """
  Activate an inner activity within a running ad-hoc subprocess.

  `process_instance_id` is the child PI, `flow_node_id` is the BPMN element
  ID of the inner activity to activate.
  """
  @spec activate_adhoc_activity(String.t(), String.t(), EvilEngine.Types.Identity.t(), keyword()) ::
          {:ok, map()} | {:error, term()} | forbidden_error()
  def activate_adhoc_activity(process_instance_id, flow_node_id, identity, opts \\ []) do
    with :ok <- Validation.check_claim(identity, "manage_adhoc_subprocess", opts) do
      Execution.activate_adhoc_activity(process_instance_id, flow_node_id)
    end
  end

  @doc """
  Signal the completion of an ad-hoc subprocess.

  The child PI will finish once all active/waiting FNIs complete.
  """
  @spec complete_adhoc_subprocess(String.t(), EvilEngine.Types.Identity.t(), keyword()) ::
          :ok | {:error, term()} | forbidden_error()
  def complete_adhoc_subprocess(process_instance_id, identity, opts \\ []) do
    with :ok <- Validation.check_claim(identity, "manage_adhoc_subprocess", opts) do
      Execution.signal_adhoc_completion(process_instance_id)
    end
  end

  @doc """
  Get the runtime status of an ad-hoc subprocess.
  """
  @spec get_adhoc_status(String.t(), EvilEngine.Types.Identity.t(), keyword()) ::
          {:ok, map()} | {:error, term()} | forbidden_error()
  def get_adhoc_status(process_instance_id, identity, opts \\ []) do
    with :ok <- Validation.check_claim(identity, "manage_adhoc_subprocess", opts) do
      Execution.get_adhoc_status(process_instance_id)
    end
  end

  # ===========================================================================
  # Data Object reads
  # ===========================================================================

  @doc "List current Data Object values (latest per data object) for a process instance."
  @spec list_data_object_values(binary(), keyword()) :: {:ok, list()} | {:error, term()}
  def list_data_object_values(process_instance_id, opts \\ []) do
    Resources.DataObject
    |> Ash.Query.filter(process_instance_id == ^process_instance_id)
    |> Ash.read(Keyword.merge([domain: @domain, authorize?: false], opts))
  end

  @doc "List Data Object history (full audit trail) for a process instance."
  @spec list_data_object_history(binary(), keyword()) :: {:ok, list()} | {:error, term()}
  def list_data_object_history(process_instance_id, opts \\ []) do
    Resources.DataObjectWrite
    |> Ash.Query.filter(process_instance_id == ^process_instance_id)
    |> Ash.read(Keyword.merge([domain: @domain, authorize?: false], opts))
  end

  @doc "Get a single Data Object value by ID."
  @spec get_data_object_value(binary(), keyword()) :: {:ok, struct()} | {:error, term()}
  def get_data_object_value(id, opts \\ []) do
    Ash.get(Resources.DataObject, id, Keyword.merge([domain: @domain, authorize?: false], opts))
  end

  # ===========================================================================
  # DMN Catalog + Evaluation
  # ===========================================================================

  @doc """
  Parse and validate a DMN XML string without persisting.

  Returns the parsed `Definitions` struct on success, or a parse/validation
  error. Useful for dry-run validation in plugins and tooling.
  """
  @spec validate_dmn(String.t()) ::
          {:ok, DMN.Model.Definitions.t()} | {:error, atom(), map()}
  def validate_dmn(raw_xml) do
    DMN.parse_and_validate(raw_xml)
  end

  @doc """
  Deploy a batch of DMN definitions.

  Accepts pre-extracted DMN entries (each `%{filename: String.t(), xml: String.t()}`),
  parses, validates, and persists.

  Validates the `deploy_dmn` claim unless `skip_claims: true`.
  """
  @spec deploy_dmn([map()], map(), keyword()) ::
          {:ok, [map()]}
          | {:error, :dmn_parse_error, list()}
          | {:error, :validation_failed, list()}
          | {:error, :version_exists, list()}
          | {:error, term()}
          | forbidden_error()
  def deploy_dmn(dmn_entries, deployer, opts \\ []) do
    with :ok <- Validation.check_claim(deployer, "deploy_dmn", opts),
         {:ok, parsed_entries} <- parse_all_dmn(dmn_entries) do
      decision_versions = extract_decision_versions(parsed_entries)
      do_deploy_dmn_batch(decision_versions, deployer, opts)
    end
  end

  @doc """
  Deploy a batch of DMN models in a single transaction.

  Each entry in `decision_versions` must have `:decision_definition_id`,
  `:version`, `:xml`, and `:definitions`. After the transaction, primes
  the DMN ModelCache.

  Validates the `deploy_dmn` claim unless `skip_claims: true`.
  """
  @spec deploy_dmn_batch([map()], map(), keyword()) ::
          {:ok, [map()]}
          | {:error, :version_exists, [map()]}
          | {:error, term()}
          | forbidden_error()
  def deploy_dmn_batch(decision_versions, deployer, opts \\ []) do
    with :ok <- Validation.check_claim(deployer, "deploy_dmn", opts) do
      do_deploy_dmn_batch(decision_versions, deployer, opts)
    end
  end

  defp do_deploy_dmn_batch(decision_versions, deployer, opts) do
    source = Keyword.get(opts, :source, derive_source(deployer))

    tx_result =
      Repo.transaction(fn ->
        decision_versions
        |> Enum.reduce_while([], &persist_single_decision_version(&1, deployer, &2))
        |> Enum.reverse()
      end)

    unwrap_dmn_deploy_result(tx_result, source)
  end

  defp parse_all_dmn(entries) do
    results =
      Enum.map(entries, fn entry ->
        case DMN.parse_and_validate(entry.xml) do
          {:ok, definitions} -> {:ok, Map.put(entry, :definitions, definitions)}
          {:error, code, metadata} -> {:error, entry.filename, code, metadata}
        end
      end)

    failures =
      results
      |> Enum.filter(&match?({:error, _, _, _}, &1))
      |> Enum.map(fn {:error, filename, code, metadata} ->
        %{file: filename, details: format_dmn_parse_error(code, metadata)}
      end)

    if failures == [] do
      successes = Enum.map(results, fn {:ok, entry} -> entry end)
      {:ok, successes}
    else
      error_type = categorize_dmn_parse_failures(failures)
      {:error, error_type, failures}
    end
  end

  defp format_dmn_parse_error(:validation_failed, %{violations: violations}) do
    Enum.map(violations, &format_dmn_violation/1)
  end

  defp format_dmn_parse_error(:dmn_parse_error, %{reason: reason}), do: [reason]

  defp format_dmn_parse_error(:feel_compile_failed, %{expression: expression, reason: reason}) do
    [
      "FEEL expression could not be compiled: '#{expression}' — #{format_dmn_diagnostic_term(reason)}"
    ]
  end

  defp format_dmn_parse_error(:import_shape_failed, metadata) do
    reason = Map.get(metadata, :reason, "unknown")

    ["DMN import shape resolution failed: #{format_dmn_diagnostic_term(reason)}"]
  end

  defp format_dmn_parse_error(code, metadata) when is_atom(code) do
    Logger.error("Unrecognized DMN deploy error #{code}: #{inspect(metadata)}")

    [
      "DMN deployment failed (#{format_dmn_error_code_label(code)}). Server logs contain the full diagnostic."
    ]
  end

  defp format_dmn_violation({_code, message}) when is_binary(message), do: message
  defp format_dmn_violation(value) when is_binary(value), do: value

  defp format_dmn_violation(other) do
    Logger.warning("Unrecognized DMN validation violation shape: #{inspect(other)}")
    "Validation issue detected. Server logs contain the technical details."
  end

  defp format_dmn_diagnostic_term(term) when is_binary(term), do: term

  defp format_dmn_diagnostic_term(term) when is_atom(term) do
    term |> Atom.to_string() |> String.replace("_", " ")
  end

  defp format_dmn_diagnostic_term({term, detail}) when is_atom(term) do
    "#{format_dmn_diagnostic_term(term)}: #{format_dmn_diagnostic_term(detail)}"
  end

  defp format_dmn_diagnostic_term(term) do
    Logger.warning("Unrecognized DMN diagnostic term shape: #{inspect(term)}")
    "see server logs for details"
  end

  defp format_dmn_error_code_label(code) when is_atom(code) do
    code |> Atom.to_string() |> String.replace("_", " ")
  end

  defp categorize_dmn_parse_failures(failures) do
    has_validation =
      Enum.any?(failures, fn failure ->
        Enum.any?(failure.details, &String.contains?(&1, "must have"))
      end)

    if has_validation, do: :validation_failed, else: :dmn_parse_error
  end

  defp extract_decision_versions(entries) do
    Enum.map(entries, fn entry ->
      definitions = entry.definitions

      %{
        decision_definition_id: definitions.id,
        name: definitions.name,
        version: extract_dmn_version(definitions),
        definitions: definitions,
        xml: entry.xml,
        filename: entry.filename
      }
    end)
  end

  defp extract_dmn_version(definitions) do
    :crypto.hash(:sha256, definitions.raw_xml)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 12)
  end

  @doc """
  Evaluate a DMN decision ad-hoc.

  Resolves the latest version, fetches from cache, evaluates,
  and returns the full `EvaluationResult` including trace.
  """
  @spec evaluate_decision(String.t(), map(), keyword()) ::
          {:ok, DMN.EvaluationResult.t()} | {:error, term()}
  def evaluate_decision(decision_definition_id, input_context, opts \\ []) do
    decision_model_id = Keyword.get(opts, :decision_model_id)
    include_unmatched = Keyword.get(opts, :include_unmatched_details, false)
    source = Keyword.get(opts, :source, "user:unknown")

    resolver = Execution.DecisionResolver.adapter()
    start_time = System.monotonic_time(:microsecond)

    with {:ok, resolved} <- resolver.resolve_latest_version(decision_definition_id),
         {:ok, definitions} <- DMN.ModelCache.fetch(resolved.decision_version_id) do
      case DMN.Evaluator.evaluate(
             definitions,
             decision_model_id,
             input_context,
             include_unmatched_details: include_unmatched,
             decision_version_id: resolved.decision_version_id
           ) do
        {:ok, _result} = success ->
          duration = System.monotonic_time(:microsecond) - start_time

          emit_decision_evaluated(
            decision_definition_id,
            decision_model_id,
            resolved.version,
            resolved.decision_version_id,
            duration,
            source
          )

          success

        {:error, error_type, metadata} ->
          {:error, {error_type, metadata}}
      end
    end
  end

  @doc """
  Evaluate a specific version of a DMN decision.

  Unlike `evaluate_decision/3`, this bypasses `DecisionResolver` and loads
  the given version directly from cache. Useful for regression testing,
  A/B comparison, and version-pinned evaluation.
  """
  @spec evaluate_decision_by_version(String.t(), String.t(), map(), keyword()) ::
          {:ok, DMN.EvaluationResult.t()} | {:error, term()}
  def evaluate_decision_by_version(
        decision_definition_id,
        version_string,
        input_context,
        opts \\ []
      ) do
    decision_model_id = Keyword.get(opts, :decision_model_id)
    include_unmatched = Keyword.get(opts, :include_unmatched_details, false)
    source = Keyword.get(opts, :source, "user:unknown")
    start_time = System.monotonic_time(:microsecond)

    with {:definition, {:ok, definition}} <-
           {:definition, get_decision_by_model_id(decision_definition_id)},
         {:version, {:ok, version}} <-
           {:version, find_decision_version_by_key(definition.id, version_string)},
         {:ok, definitions} <- DMN.ModelCache.fetch(version.id) do
      case DMN.Evaluator.evaluate(
             definitions,
             decision_model_id,
             input_context,
             include_unmatched_details: include_unmatched,
             decision_version_id: version.id
           ) do
        {:ok, _result} = success ->
          duration = System.monotonic_time(:microsecond) - start_time

          emit_decision_evaluated(
            decision_definition_id,
            decision_model_id,
            version_string,
            version.id,
            duration,
            source
          )

          success

        {:error, error_type, metadata} ->
          {:error, {error_type, metadata}}
      end
    else
      {:definition, :not_found} -> {:error, :decision_definition_not_found}
      {:version, :not_found} -> {:error, :no_version_available}
    end
  end

  @doc """
  Evaluate a DMN Decision Service ad-hoc.

  Resolves the latest version, fetches from cache, and evaluates the
  specified decision service. Returns only the output decision results.
  """
  @spec evaluate_decision_service(String.t(), String.t(), map(), keyword()) ::
          {:ok, DMN.ServiceEvaluationResult.t()} | {:error, term()}
  def evaluate_decision_service(decision_definition_id, service_id, input_context, opts \\ []) do
    source = Keyword.get(opts, :source, "user:unknown")
    resolver = Execution.DecisionResolver.adapter()
    start_time = System.monotonic_time(:microsecond)

    with {:ok, resolved} <- resolver.resolve_latest_version(decision_definition_id),
         {:ok, definitions} <- DMN.ModelCache.fetch(resolved.decision_version_id) do
      case DMN.Evaluator.evaluate_service(
             definitions,
             service_id,
             input_context,
             Keyword.put(opts, :decision_version_id, resolved.decision_version_id)
           ) do
        {:ok, _result} = success ->
          duration = System.monotonic_time(:microsecond) - start_time

          emit_decision_evaluated(
            decision_definition_id,
            service_id,
            resolved.version,
            resolved.decision_version_id,
            duration,
            source
          )

          success

        {:error, error_type, metadata} ->
          {:error, {error_type, metadata}}
      end
    end
  end

  @doc "List all decision definitions."
  @spec list_decision_definitions(keyword()) :: {:ok, list()} | {:error, term()}
  def list_decision_definitions(opts \\ []) do
    Resources.DecisionDefinition
    |> Ash.read(Keyword.merge([authorize?: false], opts))
  end

  @doc "Find a single decision definition by its `decision_definition_id`."
  @spec get_decision_by_model_id(String.t()) :: {:ok, struct()} | :not_found
  def get_decision_by_model_id(model_id) do
    case Resources.DecisionDefinition
         |> Ash.Query.filter(decision_definition_id == ^model_id)
         |> Ash.read(authorize?: false) do
      {:ok, [definition | _]} -> {:ok, definition}
      _ -> :not_found
    end
  end

  @doc "Return the latest non-deleted version for a decision definition."
  @spec get_latest_decision_version(binary()) :: {:ok, struct()} | {:error, :no_active_version}
  def get_latest_decision_version(definition_id) do
    case Resources.DecisionVersion
         |> Ash.Query.filter(decision_definition_id == ^definition_id)
         |> Ash.Query.sort(deployed_at: :desc)
         |> Ash.Query.limit(1)
         |> Ash.read(authorize?: false) do
      {:ok, [version | _]} -> {:ok, version}
      _ -> {:error, :no_active_version}
    end
  end

  @doc "Find a specific decision version by definition_id and version string."
  @spec find_decision_version_by_key(binary(), String.t()) :: {:ok, struct()} | :not_found
  def find_decision_version_by_key(definition_id, version_string) do
    case Resources.DecisionVersion
         |> Ash.Query.filter(
           decision_definition_id == ^definition_id and version == ^version_string
         )
         |> Ash.read(authorize?: false) do
      {:ok, [version | _]} -> {:ok, version}
      _ -> :not_found
    end
  end

  @doc "List all non-deleted versions for a decision definition, sorted newest-first."
  @spec list_decision_versions_for_definition(binary(), keyword()) :: list()
  def list_decision_versions_for_definition(definition_id, opts \\ []) do
    query =
      Resources.DecisionVersion
      |> Ash.Query.filter(decision_definition_id == ^definition_id)
      |> Ash.Query.sort(deployed_at: :desc)

    case Ash.read(query, Keyword.merge([authorize?: false], opts)) do
      {:ok, versions} -> versions
      _ -> []
    end
  end

  @doc """
  Toggle the `enabled` flag on a DecisionDefinition.

  Validates the `deploy_dmn` claim unless `skip_claims: true`.
  """
  @spec update_decision_enabled(struct(), boolean(), struct() | nil, keyword()) ::
          {:ok, struct()} | {:error, term()} | forbidden_error()
  def update_decision_enabled(definition, enabled_value, identity \\ nil, opts \\ []) do
    with :ok <- maybe_check_dmn_deploy_claim(identity, opts) do
      definition
      |> Ash.Changeset.for_update(:update_enabled, %{enabled: enabled_value})
      |> Ash.update(authorize?: false)
    end
  end

  defp maybe_check_dmn_deploy_claim(nil, _opts), do: :ok

  defp maybe_check_dmn_deploy_claim(identity, opts),
    do: Validation.check_claim(identity, "deploy_dmn", opts)

  @doc """
  Delete (soft-delete) a specific DMN decision version.

  Validates `delete_dmn` claim and performs the full lookup + soft-delete.
  """
  @spec delete_decision_version(String.t(), String.t(), struct(), keyword()) ::
          {:ok, struct()}
          | {:error, :not_found}
          | {:error, term()}
          | forbidden_error()
  def delete_decision_version(model_id, version_string, identity, opts \\ []) do
    with :ok <- Validation.check_claim(identity, "delete_dmn", opts),
         {:ok, definition} <- get_decision_by_model_id(model_id),
         {:ok, decision_version} <- find_decision_version_by_key(definition.id, version_string) do
      do_soft_delete_decision_version(decision_version, identity, opts)
    else
      :not_found -> {:error, :not_found}
      other -> other
    end
  end

  @doc """
  Undeploy a decision (soft-delete all versions).

  Validates `delete_dmn` claim, checks at least one active version exists.
  """
  @spec undeploy_decision(String.t(), struct(), keyword()) ::
          :ok
          | {:error, :not_found}
          | {:error, :no_active_versions}
          | {:error, term()}
          | forbidden_error()
  def undeploy_decision(model_id, identity, opts \\ []) do
    with :ok <- Validation.check_claim(identity, "delete_dmn", opts),
         {:ok, definition} <- get_decision_by_model_id(model_id) do
      do_undeploy_decision_versions(definition.id, identity, opts)
    else
      :not_found -> {:error, :not_found}
      other -> other
    end
  end

  defp do_undeploy_decision_versions(definition_id, identity, opts) do
    active_versions = list_decision_versions_for_definition(definition_id)

    if active_versions == [] do
      {:error, :no_active_versions}
    else
      results = Enum.map(active_versions, &do_soft_delete_decision_version(&1, identity, opts))

      case Enum.find(results, &match?({:error, _}, &1)) do
        nil -> :ok
        error -> error
      end
    end
  end

  @doc """
  Soft-delete a DecisionVersion and evict it from the DMN ModelCache.

  Validates the `delete_dmn` claim unless `skip_claims: true`.
  """
  @spec soft_delete_decision_version(struct(), map(), keyword()) ::
          {:ok, struct()} | {:error, term()} | forbidden_error()
  def soft_delete_decision_version(decision_version, identity, opts \\ []) do
    with :ok <- Validation.check_claim(identity, "delete_dmn", opts) do
      do_soft_delete_decision_version(decision_version, identity, opts)
    end
  end

  defp do_soft_delete_decision_version(decision_version, identity, opts) do
    source = Keyword.get(opts, :source, derive_source(identity))

    result =
      decision_version
      |> Ash.Changeset.for_update(:soft_delete, %{
        deleted: true,
        deleted_at: DateTime.utc_now(),
        deleted_by: identity
      })
      |> Ash.update(authorize?: false)

    case result do
      {:ok, _updated} = success ->
        DMN.ModelCache.delete(decision_version.id)
        emit_decision_undeployed(decision_version, source)
        success

      error ->
        error
    end
  end

  @doc "Bulk-fetch the latest version per definition for a list of definition IDs."
  @spec find_latest_decision_versions_by_definition_ids([binary()]) :: %{
          optional(binary()) => struct()
        }
  def find_latest_decision_versions_by_definition_ids(definition_ids) do
    case Resources.DecisionVersion
         |> Ash.Query.filter(decision_definition_id in ^definition_ids)
         |> Ash.Query.sort(deployed_at: :desc)
         |> Ash.read(authorize?: false) do
      {:ok, versions} ->
        Enum.reduce(versions, %{}, fn version, accumulator ->
          Map.put_new(accumulator, version.decision_definition_id, version)
        end)

      _ ->
        %{}
    end
  end

  # ===========================================================================
  # Private — DMN deploy helpers
  # ===========================================================================

  defp persist_single_decision_version(decision_version, deployer, accumulated) do
    definition =
      create_or_sync_decision_definition!(
        decision_version.decision_definition_id,
        decision_version[:name]
      )

    version_attrs = %{
      decision_definition_id: definition.id,
      version: decision_version.version,
      dmn_xml: decision_version.xml,
      deployer: deployer,
      deployed_at: DateTime.utc_now()
    }

    case create_decision_version(version_attrs) do
      {:ok, version} ->
        result = %{
          definition_id: definition.id,
          decision_definition_id: definition.decision_definition_id,
          version_id: version.id,
          version: version.version,
          definitions: decision_version.definitions
        }

        {:cont, [result | accumulated]}

      {:error, :version_exists} ->
        conflict = %{
          decision_definition_id: decision_version.decision_definition_id,
          version: decision_version.version
        }

        Repo.rollback({:version_exists, [conflict]})

      {:error, reason} ->
        if unique_decision_version_conflict?(reason) do
          conflict = %{
            decision_definition_id: decision_version.decision_definition_id,
            version: decision_version.version
          }

          Repo.rollback({:version_exists, [conflict]})
        else
          Repo.rollback(reason)
        end
    end
  end

  defp unique_decision_version_conflict?(%Ash.Changeset{errors: errors}) do
    Enum.any?(errors, &decision_version_identity_violation?/1)
  end

  defp unique_decision_version_conflict?(%Ash.Error.Unknown{errors: errors}) do
    Enum.any?(errors, &decision_version_identity_violation?/1)
  end

  defp unique_decision_version_conflict?(_), do: false

  defp create_or_sync_decision_definition!(decision_definition_id, name) do
    case Resources.DecisionDefinition
         |> Ash.Query.filter(decision_definition_id == ^decision_definition_id)
         |> Ash.read(authorize?: false) do
      {:ok, [definition | _]} ->
        definition

      _ ->
        {:ok, definition} =
          Resources.DecisionDefinition
          |> Ash.Changeset.for_create(:create, %{
            decision_definition_id: decision_definition_id,
            name: name,
            enabled: true,
            created_at: DateTime.utc_now()
          })
          |> Ash.create(authorize?: false)

        definition
    end
  end

  defp create_decision_version(attrs) do
    Resources.DecisionVersion
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create(authorize?: false)
    |> case do
      {:ok, version} ->
        {:ok, version}

      {:error, %Ash.Changeset{errors: errors} = changeset} ->
        if Enum.any?(errors, &decision_version_identity_violation?/1) do
          {:error, :version_exists}
        else
          {:error, changeset}
        end

      {:error, %Ash.Error.Unknown{errors: errors}} = error ->
        if Enum.any?(errors, &decision_version_identity_violation?/1) do
          {:error, :version_exists}
        else
          error
        end

      {:error, %Ash.Error.Invalid{errors: errors}} = error ->
        if Enum.any?(errors, &decision_version_identity_violation?/1) do
          {:error, :version_exists}
        else
          error
        end

      error ->
        error
    end
  end

  defp decision_version_identity_violation?(%{class: :invalid, field: :unique_decision_version}),
    do: true

  defp decision_version_identity_violation?(%Ash.Error.Changes.InvalidChanges{
         fields: fields,
         message: message
       })
       when is_list(fields) do
    Enum.any?(fields, &(&1 in [:decision_definition_id, :version])) or
      String.contains?(to_string(message), "unique")
  end

  defp decision_version_identity_violation?(%{error: error}) when is_binary(error) do
    decision_version_unique_constraint_message?(error)
  end

  defp decision_version_identity_violation?(_), do: false

  defp decision_version_unique_constraint_message?(message) do
    String.contains?(message, "unique_decision_version") or
      String.contains?(message, "unique_definition_version") or
      String.contains?(message, "decision_versions_unique") or
      String.contains?(message, "ConstraintError")
  end

  defp unwrap_dmn_deploy_result({:ok, results}, source) do
    Enum.each(results, fn result ->
      DMN.ModelCache.put_new(result.version_id, result.definitions)

      EngineEventBus.publish(%Event.DecisionDefinitionDeployed{
        decision_definition_id: result.decision_definition_id,
        version: result.version,
        source: source,
        occurred_at: DateTime.utc_now()
      })
    end)

    {:ok, Enum.map(results, &Map.drop(&1, [:definitions, :definition_id, :version_id]))}
  end

  defp unwrap_dmn_deploy_result({:error, {:version_exists, conflicts}}, _source) do
    {:error, :version_exists, conflicts}
  end

  defp unwrap_dmn_deploy_result({:error, %Ash.Changeset{errors: errors} = changeset}, _source) do
    if Enum.any?(errors, &decision_version_identity_violation?/1) do
      {:error, :version_exists, [decision_version_conflict_from_changeset(changeset)]}
    else
      {:error, changeset}
    end
  end

  defp unwrap_dmn_deploy_result(error, _source), do: error

  defp decision_version_conflict_from_changeset(changeset) do
    definition_uuid = changeset.attributes[:decision_definition_id]
    version = changeset.attributes[:version]

    decision_definition_id =
      case Ash.get(Resources.DecisionDefinition, definition_uuid, authorize?: false) do
        {:ok, definition} -> definition.decision_definition_id
        _ -> to_string(definition_uuid)
      end

    %{decision_definition_id: decision_definition_id, version: version}
  end

  # ===========================================================================
  # Private — Event emission helpers
  # ===========================================================================

  defp emit_decision_evaluated(
         decision_definition_id,
         decision_model_id,
         version,
         decision_version_id,
         duration_microseconds,
         source
       ) do
    EngineEventBus.publish(%Event.DecisionEvaluated{
      decision_definition_id: decision_definition_id,
      decision_model_id: decision_model_id,
      version: version,
      decision_version_id: decision_version_id,
      duration_microseconds: duration_microseconds,
      source: source,
      occurred_at: DateTime.utc_now()
    })
  end

  defp emit_process_undeployed(process_version, source) do
    process_model_id = resolve_process_model_id(process_version)

    EngineEventBus.publish(%Event.ProcessDefinitionUndeployed{
      process_model_id: process_model_id,
      version: process_version.version,
      source: source,
      occurred_at: DateTime.utc_now()
    })
  end

  defp resolve_process_model_id(process_version) do
    case Ash.get(Resources.Process, process_version.process_id, authorize?: false) do
      {:ok, process} -> process.process_model_id
      _ -> to_string(process_version.process_id)
    end
  end

  defp emit_decision_undeployed(decision_version, source) do
    definition_id = resolve_decision_definition_id(decision_version)

    EngineEventBus.publish(%Event.DecisionDefinitionUndeployed{
      decision_definition_id: definition_id,
      version: decision_version.version,
      source: source,
      occurred_at: DateTime.utc_now()
    })
  end

  defp resolve_decision_definition_id(decision_version) do
    case Ash.get(Resources.DecisionDefinition, decision_version.decision_definition_id,
           authorize?: false
         ) do
      {:ok, definition} -> definition.decision_definition_id
      _ -> to_string(decision_version.decision_definition_id)
    end
  end

  defp derive_source(%{type: "plugin", plugin_name: plugin_name}), do: "plugin:#{plugin_name}"
  defp derive_source(%{id: id}), do: "user:#{id}"
  defp derive_source(%{type: "anonymous"}), do: "user:anonymous"
  defp derive_source(_), do: "user:unknown"

  defp derive_origin(%{type: "plugin", plugin_name: plugin_name}),
    do: %{source: "plugin", plugin_name: plugin_name}

  defp derive_origin(identity),
    do: %{source: "api", triggered_by: identity.id}

  # ===========================================================================
  # Private — Shared business rule validators
  # ===========================================================================

  @terminal_states ~w(finished fatal aborted error escalated compensated)

  defp validate_user_task_type(%{flow_node_type: type})
       when type in ["user_task", "manual_task"],
       do: :ok

  defp validate_user_task_type(_), do: {:error, :not_a_user_task}

  defp validate_fni_waiting(%{state: "waiting"}), do: :ok
  defp validate_fni_waiting(%{state: "finished"}), do: {:error, :fni_already_finished}
  defp validate_fni_waiting(%{state: "aborted"}), do: {:error, :fni_already_aborted}
  defp validate_fni_waiting(%{state: "interrupted"}), do: {:error, :fni_already_interrupted}
  defp validate_fni_waiting(%{state: "fatal"}), do: {:error, :fni_already_fatal}
  defp validate_fni_waiting(_), do: {:error, :fni_not_waiting}

  defp validate_fni_active_or_waiting(%{state: state}) when state in ["active", "waiting"],
    do: :ok

  defp validate_fni_active_or_waiting(%{state: "finished"}), do: {:error, :fni_already_finished}
  defp validate_fni_active_or_waiting(%{state: "aborted"}), do: {:error, :fni_already_aborted}

  defp validate_fni_active_or_waiting(%{state: "interrupted"}),
    do: {:error, :fni_already_interrupted}

  defp validate_fni_active_or_waiting(%{state: "fatal"}), do: {:error, :fni_already_fatal}
  defp validate_fni_active_or_waiting(_), do: {:error, :fni_not_active}

  defp validate_timer_event_type(%{flow_node_type: type, event_type: "timer"})
       when type in ["intermediate_catch_event", "boundary_event"] do
    :ok
  end

  defp validate_timer_event_type(_), do: {:error, :not_a_timer_event}

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
          match?(%EvilEngine.BPMN.Model.EventDefinition.None{}, node.type_data.event_definition)
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

  defp sync_enabled(process, is_executable) do
    if process.enabled != is_executable do
      {:ok, updated} = update_process_enabled(process, is_executable)
      updated
    else
      process
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
