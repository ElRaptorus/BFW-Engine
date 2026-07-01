defmodule EvilEngineWeb.Graphql.PipelineModifier do
  @moduledoc """
  Custom Absinthe document-execution pipeline that extends the default
  `Absinthe.Plug` pipeline with the Engine's safety validation phases.

  Called at request time via `pipeline: {__MODULE__, :pipeline}` on the
  `Absinthe.Plug` forward in the router. The 2-arity `pipeline/2` signature
  receives the Absinthe.Plug config map and the pipeline options already
  containing the complexity limit (from `analyze_complexity:` / `max_complexity:`
  router options), so those work transparently.

  ## Phases added (both inserted after `Phase.Document.Validation.Result`)

  - `EvilEngineWeb.Graphql.Phases.DepthLimit` — rejects queries exceeding
    `EVIL_GRAPHQL_MAX_DEPTH` (default 10 levels of field nesting).
  - `EvilEngineWeb.Graphql.Phases.BlockIntrospection` — rejects `__schema`
    and `__type` root fields when `EVIL_GRAPHQL_INTROSPECTION_DISABLED=true`.
  """

  alias Absinthe.{Phase, Pipeline}
  alias EvilEngineWeb.Graphql.Phases.{BlockIntrospection, DepthLimit, ErrorLogger}

  @doc """
  Builds the full document-execution pipeline for incoming GraphQL requests.

  Delegates to `Absinthe.Plug.default_pipeline/2` (preserving the HTTP-method
  validation phase and complexity analysis from pipeline_opts), then appends
  the Engine's custom safety phases after the standard validation result
  and an error logger after the final result.
  """
  @spec pipeline(map(), Keyword.t()) :: Pipeline.t()
  def pipeline(config, pipeline_opts) do
    options = Pipeline.options(pipeline_opts)

    Absinthe.Plug.default_pipeline(config, pipeline_opts)
    |> Pipeline.insert_after(Phase.Document.Validation.Result, {DepthLimit, options})
    |> Pipeline.insert_after(Phase.Document.Validation.Result, {BlockIntrospection, options})
    |> Pipeline.insert_after(Phase.Document.Result, {ErrorLogger, options})
  end
end
