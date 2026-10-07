defmodule BfwEngine.Api.Processes do
  @moduledoc """
  Process catalog reads, writes, and deployment.
  Callers use `BfwEngine.Api`.
  """

  require Ash.Query
  require Logger

  alias BfwEngine.Api.AshWrite
  alias BfwEngine.Api.ProcessInstances
  alias BfwEngine.Api.Validation
  alias BfwEngine.BPMN
  alias BfwEngine.BPMN.LinterGate
  alias BfwEngine.BPMN.ModelCache
  alias BfwEngine.Events.EngineEventBus
  alias BfwEngine.Persistence.Repo
  alias BfwEngine.Persistence.Resources
  alias BfwEngine.Timers.StartEventManager
  alias BfwEngine.Types.Event

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
          |> AshWrite.ash_create()

        process
    end
  end

  @doc """
  Toggle the `enabled` flag on a Process.

  Validates the `deploy_bpmn` claim unless `skip_claims: true`.
  Accepts an optional `identity` for claim checking.
  """
  @spec update_process_enabled(struct(), boolean(), keyword()) ::
          {:ok, struct()} | {:error, term()} | BfwEngine.Api.forbidden_error()
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
    |> AshWrite.ash_create()
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
          | BfwEngine.Api.forbidden_error()
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
          | BfwEngine.Api.forbidden_error()
  def persist_deploy_batch(process_versions, deployer, opts \\ []) do
    with :ok <- Validation.check_claim(deployer, "deploy_bpmn", opts) do
      do_persist_deploy_batch(process_versions, deployer, opts)
    end
  end

  defp do_persist_deploy_batch(process_versions, deployer, opts) do
    source = Keyword.get(opts, :source, derive_source(deployer))
    AshWrite.stash_ash_notifications()

    tx_result =
      Repo.transaction(fn ->
        process_versions
        |> Enum.reduce_while([], &persist_single_version(&1, deployer, &2))
        |> Enum.reverse()
      end)

    AshWrite.flush_ash_notifications(tx_result)
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
      %BfwEngine.BPMN.Model.EventDefinition.Timer{},
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

  @spec fetch_existing_version_set([binary()]) ::
          {:ok, %{optional({binary(), binary()}) => true}} | {:error, term()}
  defp fetch_existing_version_set(process_ids) do
    case Resources.ProcessVersion
         |> Ash.Query.filter(process_id in ^process_ids)
         |> Ash.read(authorize?: false) do
      {:ok, versions} ->
        {:ok, Map.new(versions, fn v -> {{v.process_id, v.version}, true} end)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Delete (soft-delete) a specific BPMN process version.

  Validates `delete_bpmn` claim and that no active PIs exist on this version.
  """
  @spec delete_process_version(String.t(), String.t(), struct(), keyword()) ::
          {:ok, struct()}
          | {:error, :not_found}
          | {:error, :active_instances_exist}
          | {:error, term()}
          | BfwEngine.Api.forbidden_error()
  def delete_process_version(model_id, version_string, identity, opts \\ []) do
    with :ok <- Validation.check_claim(identity, "delete_bpmn", opts),
         {:ok, process} <- get_process_by_model_id(model_id),
         {:ok, process_version} <- find_process_version_by_key(process.id, version_string),
         false <- ProcessInstances.has_active_process_instances?(process_version.id) do
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
          | BfwEngine.Api.forbidden_error()
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

      ProcessInstances.any_active_process_instances?(Enum.map(active_versions, & &1.id)) ->
        {:error, :active_instances_exist}

      true ->
        results = Enum.map(active_versions, &soft_delete_process_version(&1, identity, opts))

        case Enum.find(results, &match?({:error, _}, &1)) do
          nil -> :ok
          error -> error
        end
    end
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

  defp derive_source(%{type: "plugin", plugin_name: plugin_name}), do: "plugin:#{plugin_name}"
  defp derive_source(%{id: id}), do: "user:#{id}"
  defp derive_source(%{type: "anonymous"}), do: "user:anonymous"
  defp derive_source(_), do: "user:unknown"

  defp sync_enabled(process, is_executable) do
    if process.enabled != is_executable do
      {:ok, updated} = update_process_enabled(process, is_executable)
      updated
    else
      process
    end
  end
end
