defmodule EvilEngineWeb.Graphql.Schema do
  @moduledoc """
  Absinthe schema, auto-extended by AshGraphql from every
  Ash resource on the `EvilEngine.Persistence.Api` domain.

  AshGraphql derives queries from resource `graphql` blocks:
  `processes`, `processVersions`, `processInstances`, `flowNodeInstances`.

  Safety limits (S-4):
  - Depth limiting via `EvilEngineWeb.Graphql.Phases.DepthLimit` (env:
    `EVIL_GRAPHQL_MAX_DEPTH`, default 10).
  - Introspection blocking via `EvilEngineWeb.Graphql.Phases.BlockIntrospection`
    (env: `EVIL_GRAPHQL_INTROSPECTION_DISABLED`, default false).
  - Complexity limiting is configured on the `Absinthe.Plug` forward in the
    router (env: `EVIL_GRAPHQL_MAX_COMPLEXITY`, default 1000).
  """

  use Absinthe.Schema

  use AshGraphql, domains: [EvilEngine.Persistence.Api]

  query do
  end
end
