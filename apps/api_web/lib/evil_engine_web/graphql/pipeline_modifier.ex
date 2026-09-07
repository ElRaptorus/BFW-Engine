defmodule EvilEngineWeb.Graphql.PipelineModifier do
  @moduledoc """
  Custom Absinthe document-execution pipeline that extends the default
  `Absinthe.Plug` pipeline with the Engine's safety validation phases.

  Called at request time via `pipeline: {__MODULE__, :pipeline}` on the
  `Absinthe.Plug` forward in the router.

  `max_complexity` is overwritten from `Application.get_env/3` on every
  request so `TDE_GRAPHQL_MAX_COMPLEXITY` takes effect without recompiling.
  The router's `compile_env` value is only a fallback for Absinthe.Plug init.

  ## Phases added (both inserted after `Phase.Document.Validation.Result`)

  - `EvilEngineWeb.Graphql.Phases.DepthLimit` — rejects queries exceeding
    `TDE_GRAPHQL_MAX_DEPTH` (default 16 levels of field nesting).
  - `EvilEngineWeb.Graphql.Phases.BlockIntrospection` — rejects `__schema`
    and `__type` root fields when `TDE_GRAPHQL_INTROSPECTION_DISABLED=true`.
  """

  alias Absinthe.{Phase, Pipeline}
  alias EvilEngineWeb.Graphql.Phases.{BlockIntrospection, DepthLimit, ErrorLogger}

  # Sized for the Studio debugger snapshot: `dataObjectValues(limit: 500)` plus
  # page metadata scores 6500 under AshGraphql's `limit * child_complexity`.
  @default_max_complexity 10_000

  @doc """
  Builds the full document-execution pipeline for incoming GraphQL requests.

  Delegates to `Absinthe.Plug.default_pipeline/2` (preserving the HTTP-method
  validation phase and complexity analysis), injects the runtime complexity
  cap, then appends the Engine's custom safety phases after the standard
  validation result and an error logger after the final result.
  """
  @spec pipeline(map(), Keyword.t()) :: Pipeline.t()
  def pipeline(config, pipeline_opts) do
    pipeline_opts = Keyword.put(pipeline_opts, :max_complexity, max_complexity())
    options = Pipeline.options(pipeline_opts)

    Absinthe.Plug.default_pipeline(config, pipeline_opts)
    |> Pipeline.insert_after(Phase.Document.Validation.Result, {DepthLimit, options})
    |> Pipeline.insert_after(Phase.Document.Validation.Result, {BlockIntrospection, options})
    |> Pipeline.insert_after(Phase.Document.Result, {ErrorLogger, options})
  end

  @doc """
  Current GraphQL complexity cap. Read at request time from
  `:api_web, :graphql_max_complexity` (`TDE_GRAPHQL_MAX_COMPLEXITY`).
  """
  @spec max_complexity() :: pos_integer()
  def max_complexity do
    Application.get_env(:api_web, :graphql_max_complexity, @default_max_complexity)
  end
end
