defmodule BfwEngineWeb.Graphql.ModelResolvers do
  @moduledoc """
  Resolvers for the BPMN Model graph (WP-3).

  Two responsibilities:

  1. **Flattening** — `to_graphql_flow_node/2` merges a `FlowNode`'s
     polymorphic `type_data` onto its own fields, so every field declared
     in `ModelTypes` resolves via Absinthe's default `Map.get/2` behaviour
     without a per-field custom resolver. Recurses into nested
     `SubProcess.flow_nodes` / `sequence_flows`.
  2. **Entry points** — `resolve_process_model/3` (`ProcessVersion.processModel`),
     `resolve_flow_node/3` (`FlowNodeInstance.flowNode`), and
     `resolve_process_version/3` (`FlowNodeInstance.processVersion`).

  `resolve_process_model/3` and `resolve_flow_node/3` batch the
  `ModelCache.fetch/1` step through the `:model_cache` Dataloader source
  (`BfwEngineWeb.Graphql.Dataloader.ModelCacheSource`): Dataloader's own
  batching guarantees the source's `load/2` function — and therefore
  `ModelCache.fetch/1` — is invoked at most once per distinct
  `process_version_id` per request tick, regardless of how many
  `FlowNodeInstance`s in the response share that version (WP-3.4 / WP-7 v).

  The `FlowNodeInstance → ProcessInstance → process_version_id` hop
  (§1.2 gap: no direct Ash relationship) is **not** Dataloader-batched —
  it is a plain `Ash.get/3` per call. Batching it would need a second,
  Ash-backed Dataloader source; tracked as a follow-up, not required by
  WP-3.4's stated guarantee (which is specifically about `ModelCache.fetch/1`).
  """

  import Absinthe.Resolution.Helpers, only: [on_load: 2]

  alias BfwEngine.BPMN.Model
  alias BfwEngine.BPMN.ModelCache
  alias BfwEngine.Persistence.Resources.ProcessInstance
  alias BfwEngine.Persistence.Resources.ProcessVersion

  @doc """
  Flattens a `%Model.FlowNode{}` into a plain map suitable for Absinthe
  resolution against the `:flow_node` interface. `parent_sub_process_id`
  is `nil` unless the caller is building the flat `allFlowNodes` index.
  """
  @spec to_graphql_flow_node(Model.FlowNode.t(), String.t() | nil) :: map()
  def to_graphql_flow_node(%Model.FlowNode{} = flow_node, parent_sub_process_id \\ nil) do
    type_data_fields = flatten_type_data(flow_node.type_data)

    flow_node
    |> Map.from_struct()
    |> Map.drop([:type_data])
    |> Map.merge(type_data_fields)
    |> Map.put(:parent_sub_process_id, parent_sub_process_id)
  end

  # SubProcess is the only type_data variant holding nested FlowNode /
  # SequenceFlow structs — recurse so the nested tree is flattened too.
  # Every other variant's fields already match the GraphQL field names
  # 1:1 (see ModelTypes / FieldTable), so a plain struct-to-map is enough.
  defp flatten_type_data(%Model.FlowNodeData.SubProcess{} = sub_process) do
    sub_process
    |> Map.from_struct()
    |> Map.drop([:adhoc_completion_condition_compiled, :active_elements_compiled])
    |> Map.put(:flow_nodes, Enum.map(sub_process.flow_nodes, &to_graphql_flow_node(&1, nil)))
    |> Map.put(:sequence_flows, Enum.map(sub_process.sequence_flows, &Map.from_struct/1))
  end

  defp flatten_type_data(type_data) when is_struct(type_data) do
    Map.from_struct(type_data)
  end

  @doc """
  Flattens a `%Model.Process{}` into a GraphQL-ready map: the nested
  `flowNodes` tree plus the flat `allFlowNodes` index (D-2 = C).

  When a `%Model.Definitions{}` is supplied, its catalogs (`messages`,
  `signals`, `errors`, `escalations`, `linter_scores`) and `definitions_id`
  are copied onto the result — those live on `Definitions`, not `Process`,
  but are exposed on `ProcessModel` so clients do not need a second type.
  """
  @spec to_graphql_process_model(Model.Process.t(), Model.Definitions.t() | nil) :: map()
  def to_graphql_process_model(%Model.Process{} = process, definitions \\ nil) do
    process
    |> Map.from_struct()
    |> Map.drop([:inclusive_join_analyses, :complex_region_analyses])
    |> Map.put(:flow_nodes, Enum.map(process.flow_nodes, &to_graphql_flow_node(&1, nil)))
    |> Map.put(:all_flow_nodes, collect_all_flow_nodes(process.flow_nodes, nil))
    |> Map.put(:sequence_flows, Enum.map(process.sequence_flows, &Map.from_struct/1))
    |> Map.put(:data_objects, Enum.map(process.data_objects, &Map.from_struct/1))
    |> Map.put(
      :data_object_references,
      Enum.map(process.data_object_references, &Map.from_struct/1)
    )
    |> Map.put(:associations, Enum.map(process.associations, &Map.from_struct/1))
    |> Map.put(:lanes, Enum.map(process.lanes, &Map.from_struct/1))
    |> Map.put(:extensions, Enum.map(process.extensions, &extension_to_map/1))
    |> attach_definition_catalogs(definitions)
  end

  # Walks every scope (top-level and every nested SubProcess), flattening
  # each FlowNode with its enclosing shell's id as parent_sub_process_id.
  @spec collect_all_flow_nodes([Model.FlowNode.t()], String.t() | nil) :: [map()]
  defp collect_all_flow_nodes(flow_nodes, parent_id) do
    Enum.flat_map(flow_nodes, fn flow_node ->
      here = [to_graphql_flow_node(flow_node, parent_id)]

      case flow_node.type_data do
        %Model.FlowNodeData.SubProcess{flow_nodes: nested} ->
          here ++ collect_all_flow_nodes(nested, flow_node.id)

        _ ->
          here
      end
    end)
  end

  @doc """
  Selects the single process to expose as `ProcessModel` from a
  `Definitions.t()`. Ambiguity rule (WP-3.1): exactly one executable
  process is required; zero or multiple is an error.
  """
  @spec select_process(Model.Definitions.t()) ::
          {:ok, Model.Process.t()}
          | {:error, :no_executable_process | :multiple_executable_processes}
  def select_process(%Model.Definitions{processes: processes}) do
    case Enum.filter(processes, & &1.is_executable) do
      [process] -> {:ok, process}
      [] -> {:error, :no_executable_process}
      _ -> {:error, :multiple_executable_processes}
    end
  end

  @doc "Resolver for `ProcessVersion.processModel`."
  def resolve_process_model(process_version, _args, %{context: %{loader: loader}}) do
    loader
    |> Dataloader.load(:model_cache, :definitions, process_version.id)
    |> on_load(fn loader ->
      loader
      |> Dataloader.get(:model_cache, :definitions, process_version.id)
      |> definitions_to_process_model_result()
    end)
  end

  @doc """
  Resolver for `FlowNodeInstance.processVersion`. No direct Ash
  relationship exists (§1.2 gap) — hops through the parent
  `ProcessInstance`. Not Dataloader-batched; see the moduledoc.
  """
  def resolve_process_version(flow_node_instance, _args, %{context: %{actor: actor}}) do
    with {:ok, flow_node_instance} <- ensure_required_ids_loaded(flow_node_instance, actor),
         {:ok, process_instance} <- load_process_instance(flow_node_instance, actor) do
      case process_instance do
        nil ->
          {:ok, nil}

        process_instance ->
          Ash.get(ProcessVersion, process_instance.process_version_id, actor: actor)
      end
    end
  end

  @doc """
  Resolver for `FlowNodeInstance.flowNode`. Resolves the FNI's
  `process_version_id` (via the same hop as `resolve_process_version/3`),
  then looks the node up in the **flat** `allFlowNodes` index so nodes
  inside any nested subprocess scope are reachable (D-2 = C).
  """
  def resolve_flow_node(flow_node_instance, _args, %{context: %{actor: actor, loader: loader}}) do
    with {:ok, flow_node_instance} <- ensure_required_ids_loaded(flow_node_instance, actor),
         {:ok, process_instance} <- load_process_instance(flow_node_instance, actor) do
      case process_instance do
        nil ->
          {:ok, nil}

        process_instance ->
          load_flow_node(
            loader,
            process_instance.process_version_id,
            flow_node_instance.flow_node_id
          )
      end
    end
  end

  defp load_flow_node(loader, process_version_id, flow_node_id) do
    loader
    |> Dataloader.load(:model_cache, :definitions, process_version_id)
    |> on_load(fn loader ->
      loader
      |> Dataloader.get(:model_cache, :definitions, process_version_id)
      |> find_flow_node_by_id(flow_node_id)
    end)
  end

  # AshGraphql only loads the attributes explicitly selected in the client's
  # GraphQL query. `process_instance_id` and `flow_node_id` are required by
  # these resolvers regardless of whether the client asked for them as
  # scalar fields — reload them if AshGraphql left them as `%Ash.NotLoaded{}`.
  defp ensure_required_ids_loaded(flow_node_instance, actor) do
    if match?(%Ash.NotLoaded{}, flow_node_instance.process_instance_id) or
         match?(%Ash.NotLoaded{}, flow_node_instance.flow_node_id) do
      Ash.load(flow_node_instance, [:process_instance_id, :flow_node_id], actor: actor)
    else
      {:ok, flow_node_instance}
    end
  end

  defp load_process_instance(flow_node_instance, actor) do
    case Ash.get(ProcessInstance, flow_node_instance.process_instance_id, actor: actor) do
      {:ok, process_instance} -> {:ok, process_instance}
      {:error, %Ash.Error.Query.NotFound{}} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp definitions_to_process_model_result({:ok, definitions}) do
    case select_process(definitions) do
      {:ok, process} -> {:ok, to_graphql_process_model(process, definitions)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp definitions_to_process_model_result({:error, :not_found}), do: {:ok, nil}
  defp definitions_to_process_model_result({:error, reason}), do: {:error, reason}

  defp find_flow_node_by_id({:ok, definitions}, flow_node_id) do
    with {:ok, process} <- select_process(definitions) do
      process
      |> to_graphql_process_model(definitions)
      |> Map.fetch!(:all_flow_nodes)
      |> Enum.find(&(&1.id == flow_node_id))
      |> then(&{:ok, &1})
    end
  end

  defp find_flow_node_by_id({:error, :not_found}, _flow_node_id), do: {:ok, nil}
  defp find_flow_node_by_id({:error, reason}, _flow_node_id), do: {:error, reason}

  @doc """
  Non-Dataloader entry point used by tests and by resolvers that already
  hold a `process_version_id`. Delegates straight to `ModelCache.fetch/1`.

  No `@spec` is declared here: the success map shape is the flattened,
  struct-dependent output of `to_graphql_process_model/1`, and the error
  union additionally includes whatever `ModelCache.fetch/1` itself can
  surface (e.g. `{:load_task_crashed, reason}`) — a broad `map()`/`term()`
  contract would be flagged as an `:underspecs` `contract_supertype` by
  Dialyzer, and a fully precise one would duplicate `ModelCache`'s own spec.
  """
  def load_process_model(process_version_id) do
    with {:ok, definitions} <- ModelCache.fetch(process_version_id),
         {:ok, process} <- select_process(definitions) do
      {:ok, to_graphql_process_model(process, definitions)}
    end
  end

  defp attach_definition_catalogs(process_model, nil) do
    process_model
    |> Map.put(:definitions_id, nil)
    |> Map.put(:messages, [])
    |> Map.put(:signals, [])
    |> Map.put(:errors, [])
    |> Map.put(:escalations, [])
    |> Map.put(:linter_scores, [])
  end

  defp attach_definition_catalogs(process_model, %Model.Definitions{} = definitions) do
    process_model
    |> Map.put(:definitions_id, definitions.definitions_id)
    |> Map.put(:messages, Enum.map(definitions.messages, &Map.from_struct/1))
    |> Map.put(:signals, Enum.map(definitions.signals, &Map.from_struct/1))
    |> Map.put(:errors, Enum.map(definitions.errors, &Map.from_struct/1))
    |> Map.put(:escalations, Enum.map(definitions.escalations, &Map.from_struct/1))
    |> Map.put(:linter_scores, Enum.map(definitions.linter_scores, &Map.from_struct/1))
  end

  defp extension_to_map(%Model.Extension{} = extension) do
    extension
    |> Map.from_struct()
    |> Map.put(:children, Enum.map(extension.children, &extension_to_map/1))
  end
end
