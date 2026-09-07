defmodule EvilEngineWeb.Graphql.Schema do
  @moduledoc """
  Absinthe schema, auto-extended by AshGraphql from every
  Ash resource on the `EvilEngine.Persistence.Api` domain, plus the
  hand-written BPMN Model graph (Phase 6.1, `ModelTypes` / `ModelResolvers`).

  AshGraphql derives queries from resource `graphql` blocks:
  `processes`, `processVersions`, `processInstances`, `flowNodeInstances`.

  The Model graph adds three fields resolved from `ModelCache` rather than
  the database: `ProcessVersion.processModel`, `FlowNodeInstance.flowNode`,
  and `FlowNodeInstance.processVersion` (§1.2: no direct Ash relationship
  exists for the latter).

  Safety limits (S-4):
  - Depth limiting via `EvilEngineWeb.Graphql.Phases.DepthLimit` (env:
    `TDE_GRAPHQL_MAX_DEPTH`, default 16, sized for recursive
    `SubProcessNode.flowNodes` — see WP-7 / `common-pitfalls.md` §P64).
  - Introspection blocking via `EvilEngineWeb.Graphql.Phases.BlockIntrospection`
    (env: `TDE_GRAPHQL_INTROSPECTION_DISABLED`, default false).
  - Complexity limiting is applied at request time by `PipelineModifier`
    (env: `TDE_GRAPHQL_MAX_COMPLEXITY`, default 10000, sized for the Studio
    debugger `dataObjectValues(limit: 500)` snapshot).

  Dataloader is registered as `:model_cache` (see `context/1`), batching
  `EvilEngine.BPMN.ModelCache.fetch/1` per distinct `process_version_id`.
  """

  use Absinthe.Schema

  use AshGraphql, domains: [EvilEngine.Persistence.Api]

  import_types(EvilEngineWeb.Graphql.ModelTypes)

  alias EvilEngineWeb.Graphql.Dataloader.ModelCacheSource
  alias EvilEngineWeb.Graphql.ModelResolvers

  query do
  end

  extend object(:process_version) do
    @desc "The parsed BPMN process for this version, resolved from ModelCache (not the database). Null if the model has been evicted and cannot be reloaded (e.g. the source XML is gone)."
    field :process_model, :process_model do
      resolve(&ModelResolvers.resolve_process_model/3)
    end
  end

  extend object(:flow_node_instance) do
    @desc "The BPMN flow node this instance ran, resolved from ModelCache's flat, every-scope index. Reaches nodes inside any nested subprocess scope."
    field :flow_node, :flow_node do
      resolve(&ModelResolvers.resolve_flow_node/3)
    end

    @desc "The process version this instance ran against. No direct persistence relationship exists — resolved via the parent ProcessInstance."
    field :process_version, :process_version do
      resolve(&ModelResolvers.resolve_process_version/3)
    end
  end

  def context(context) do
    # `get_policy: :tuples` is required — the default `:raise_on_error`
    # would turn `ModelCache.fetch/1`'s `{:error, :not_found}` (a normal,
    # expected outcome when a version's source XML has been evicted) into
    # a raised `Dataloader.GetError`. `ModelResolvers.definitions_to_process_model_result/1`
    # and `find_flow_node_by_id/2` pattern-match on the `{:ok, _}` / `{:error, _}`
    # tuple returned by `Dataloader.get/3` under this policy.
    loader =
      Dataloader.new(get_policy: :tuples)
      |> Dataloader.add_source(:model_cache, ModelCacheSource.data())

    Map.put(context, :loader, loader)
  end

  def plugins do
    [Absinthe.Middleware.Dataloader | Absinthe.Plugin.defaults()]
  end
end
