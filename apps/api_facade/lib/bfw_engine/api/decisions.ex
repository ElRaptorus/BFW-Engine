defmodule BfwEngine.Api.Decisions do
  @moduledoc """
  DMN decision catalog and evaluation.
  Callers use `BfwEngine.Api`.
  """

  require Ash.Query
  require Logger

  alias BfwEngine.Api.AshWrite
  alias BfwEngine.Api.Validation
  alias BfwEngine.DMN
  alias BfwEngine.Events.EngineEventBus
  alias BfwEngine.Execution
  alias BfwEngine.Persistence.Repo
  alias BfwEngine.Persistence.Resources
  alias BfwEngine.Types.Event

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
          | BfwEngine.Api.forbidden_error()
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
          | BfwEngine.Api.forbidden_error()
  def deploy_dmn_batch(decision_versions, deployer, opts \\ []) do
    with :ok <- Validation.check_claim(deployer, "deploy_dmn", opts) do
      do_deploy_dmn_batch(decision_versions, deployer, opts)
    end
  end

  defp do_deploy_dmn_batch(decision_versions, deployer, opts) do
    source = Keyword.get(opts, :source, derive_source(deployer))
    AshWrite.stash_ash_notifications()

    tx_result =
      Repo.transaction(fn ->
        decision_versions
        |> Enum.reduce_while([], &persist_single_decision_version(&1, deployer, &2))
        |> Enum.reverse()
      end)

    AshWrite.flush_ash_notifications(tx_result)
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
          {:ok, struct()} | {:error, term()} | BfwEngine.Api.forbidden_error()
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
          | BfwEngine.Api.forbidden_error()
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
          | BfwEngine.Api.forbidden_error()
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
          {:ok, struct()} | {:error, term()} | BfwEngine.Api.forbidden_error()
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
          |> AshWrite.ash_create()

        definition
    end
  end

  defp create_decision_version(attrs) do
    Resources.DecisionVersion
    |> Ash.Changeset.for_create(:create, attrs)
    |> AshWrite.ash_create()
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
end
