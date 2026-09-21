defmodule BfwEngine.EngineFacade.Graphql do
  @moduledoc """
  Runtime namespace for GraphQL query execution.

  Provides a single `query/2` closure that executes a raw GraphQL
  query string with variables against the engine's Absinthe schema.
  For in-BEAM plugins, this runs via `Absinthe.run/3` with the
  plugin's synthetic identity as actor context — no HTTP round-trip.

  The full typed query surface (per-resource query methods) is
  defined in the TypeScript SDK `FacadeGraphql` interface. On the
  Elixir side, the single `query` closure is sufficient because
  Elixir plugins construct their own query strings.
  """

  @type t :: %__MODULE__{
          query: (String.t(), map() -> {:ok, map()} | {:error, term()})
        }

  defstruct query: &__MODULE__.noop_2/2

  @doc false
  @spec noop_2(term(), term()) :: {:error, :not_wired}
  def noop_2(_a, _b), do: {:error, :not_wired}
end
