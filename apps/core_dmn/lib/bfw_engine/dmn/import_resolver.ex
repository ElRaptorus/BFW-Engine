defmodule BfwEngine.DMN.ImportResolver do
  @moduledoc """
  Resolves DMN cross-model `<import>` references at deploy time and
  evaluation time.

  Import lookup is injected via a resolver function (same pattern as
  `BfwEngine.Execution.CalledElementResolver`). At deploy time,
  `validate_imports/2` verifies that every declared import namespace
  is reachable and that the import graph has no cycles. At evaluation
  time, `resolve_imported_element/3` resolves qualified DRG references
  against the local model and a map of already-resolved imports.
  """

  alias BfwEngine.DMN.Model.BusinessKnowledgeModel
  alias BfwEngine.DMN.Model.Decision
  alias BfwEngine.DMN.Model.Definitions
  alias BfwEngine.DMN.Model.Import
  alias BfwEngine.DMN.Model.InputData
  alias BfwEngine.DMN.ModelCache
  alias BfwEngine.DMN.QualifiedReference

  @type resolver :: (String.t() -> {:ok, Definitions.t()} | {:error, term()})

  @type resolved_imports :: %{String.t() => Definitions.t()}

  @type violation :: {atom(), String.t()}

  @type resolved_element ::
          {:decision, Decision.t()}
          | {:input_data, InputData.t()}
          | {:business_knowledge_model, BusinessKnowledgeModel.t()}

  @doc """
  Resolves every `<import>` on `definitions` via `resolver`.

  Returns `{:ok, %{namespace => %Definitions{}}}` when all imports resolve,
  or `{:error, :import_not_found, %{namespace: namespace}}` on the first miss.
  """
  @spec resolve_imports(Definitions.t(), resolver()) ::
          {:ok, resolved_imports()} | {:error, :import_not_found, %{namespace: String.t()}}
  def resolve_imports(%Definitions{imports: imports}, resolver) when is_function(resolver, 1) do
    Enum.reduce_while(imports, {:ok, %{}}, fn %Import{namespace: namespace}, {:ok, accumulator} ->
      case resolver.(namespace) do
        {:ok, imported_definitions} ->
          {:cont, {:ok, Map.put(accumulator, namespace, imported_definitions)}}

        {:error, _reason} ->
          {:halt, {:error, :import_not_found, %{namespace: namespace}}}
      end
    end)
  end

  @doc """
  Walks the import graph starting from a deployed model's `namespace`.

  The root model is loaded via `resolver`; each transitive import is
  followed recursively. Returns `:ok` when no cycle exists, or
  `{:error, :circular_import, %{chain: namespaces}}` with the namespace
  chain that closed the loop.
  """
  @spec detect_circular_imports(String.t(), resolver()) ::
          :ok | {:error, :circular_import, %{chain: [String.t()]}}
  def detect_circular_imports(namespace, resolver) when is_binary(namespace) and is_function(resolver, 1) do
    case resolver.(namespace) do
      {:ok, %Definitions{imports: imports}} ->
        detect_circular_imports_from_imports(imports, resolver, [namespace])

      {:error, _reason} ->
        :ok
    end
  end

  @doc """
  Deploy-time validation: resolve all imports and reject circular graphs.

  Uses `definitions` for the root model's direct imports (the model being
  deployed may not yet be in the resolver). Transitive imports are loaded
  through `resolver`.

  Returns `{:ok, resolved_imports}` or `{:error, violations}` where each
  violation is `{atom(), message}`.
  """
  @spec validate_imports(Definitions.t(), resolver()) ::
          {:ok, resolved_imports()} | {:error, [violation()]}
  def validate_imports(%Definitions{} = definitions, resolver) when is_function(resolver, 1) do
    ancestor_namespaces = if definitions.namespace, do: [definitions.namespace], else: []

    with :ok <- detect_circular_imports_from_imports(definitions.imports, resolver, ancestor_namespaces),
         {:ok, resolved_imports} <- resolve_imports(definitions, resolver) do
      {:ok, resolved_imports}
    else
      {:error, :import_not_found, metadata} ->
        {:error, [violation_tuple(:import_not_found, metadata)]}

      {:error, :circular_import, metadata} ->
        {:error, [violation_tuple(:circular_import, metadata)]}
    end
  end

  @doc """
  Resolves a qualified DRG reference to a model element.

  `qualified_reference` is either a local id (e.g. `"Decision_discount"`) or
  a namespace-qualified id (e.g. `"https://example.com/dmn/helpers#Decision_x"`).

  Returns `{:ok, {:decision, _}}`, `{:ok, {:input_data, _}}`, or
  `{:ok, {:business_knowledge_model, _}}`, or an error tuple.
  """
  @spec resolve_imported_element(String.t(), Definitions.t(), resolved_imports()) ::
          {:ok, resolved_element()}
          | {:error, :import_not_found, %{namespace: String.t()}}
          | {:error, :element_not_found, %{qualified_reference: String.t(), element_id: String.t()}}
          | {:error, :invalid_qualified_reference, %{qualified_reference: String.t()}}
  def resolve_imported_element(qualified_reference, %Definitions{} = local_definitions, resolved_imports)
      when is_binary(qualified_reference) and is_map(resolved_imports) do
    case QualifiedReference.split(qualified_reference) do
      {:local, element_id} ->
        find_element_in_definitions(local_definitions, element_id, qualified_reference)

      {:imported, namespace, element_id} ->
        case Map.fetch(resolved_imports, namespace) do
          {:ok, imported_definitions} ->
            find_element_in_definitions(imported_definitions, element_id, qualified_reference)

          :error ->
            {:error, :import_not_found, %{namespace: namespace}}
        end

      :invalid ->
        {:error, :invalid_qualified_reference, %{qualified_reference: qualified_reference}}
    end
  end

  @doc """
  Builds a resolver function that looks up deployed models by namespace
  from the in-memory `ModelCache`.

  Uses the namespace index for O(1) lookup. When multiple versions share
  a namespace, the most recently cached version wins.
  """
  @spec build_model_cache_resolver() :: resolver()
  def build_model_cache_resolver do
    fn namespace ->
      ModelCache.lookup_by_namespace(namespace)
    end
  end

  defp detect_circular_imports_from_imports(imports, resolver, ancestor_namespaces) do
    Enum.reduce_while(imports, :ok, fn %Import{namespace: namespace}, :ok ->
      case walk_import_chain(namespace, resolver, ancestor_namespaces) do
        :ok -> {:cont, :ok}
        {:error, _, _} = error -> {:halt, error}
      end
    end)
  end

  defp walk_import_chain(namespace, resolver, ancestor_namespaces) do
    if namespace in ancestor_namespaces do
      {:error, :circular_import, %{chain: ancestor_namespaces ++ [namespace]}}
    else
      case resolver.(namespace) do
        {:ok, %Definitions{imports: imports}} ->
          detect_circular_imports_from_imports(imports, resolver, ancestor_namespaces ++ [namespace])

        {:error, _reason} ->
          :ok
      end
    end
  end

  defp find_element_in_definitions(%Definitions{} = definitions, element_id, qualified_reference) do
    cond do
      decision = Enum.find(definitions.decisions, &(&1.id == element_id)) ->
        {:ok, {:decision, decision}}

      input_data = Enum.find(definitions.input_data, &(&1.id == element_id)) ->
        {:ok, {:input_data, input_data}}

      business_knowledge_model =
          Enum.find(definitions.business_knowledge_models, &(&1.id == element_id)) ->
        {:ok, {:business_knowledge_model, business_knowledge_model}}

      true ->
        {:error, :element_not_found,
         %{qualified_reference: qualified_reference, element_id: element_id}}
    end
  end

  defp violation_tuple(:import_not_found, %{namespace: namespace}) do
    {:import_not_found, "Import namespace '#{namespace}' is not deployed"}
  end

  defp violation_tuple(:circular_import, %{chain: chain}) do
    {:circular_import, "Circular import detected: #{Enum.join(chain, " -> ")}"}
  end
end
