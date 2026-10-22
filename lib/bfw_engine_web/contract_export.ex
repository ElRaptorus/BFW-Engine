defmodule BfwEngineWeb.ContractExport do
  @moduledoc """
  Renders the machine-readable wire contracts that other engines and clients
  vendor: the GraphQL SDL and the OpenAPI document.

  Both files are committed under `contracts/` at the repository root. The
  `mix bfw.gen.contracts` task writes them, and `mix bfw.gen.contracts --check`
  (part of `mix quality`) fails when a committed copy has drifted.

  The OpenAPI JSON is the content of `priv/openapi/spec.yaml` without the
  `servers` block that `BfwEngineWeb.Http.OpenApiSpecLoader` injects at runtime,
  so the export does not depend on the configured HTTP port. Object keys are
  sorted so the output is byte-stable across Erlang/OTP versions.
  """

  alias BfwEngineWeb.Graphql.Schema

  @graphql_path "contracts/graphql/schema.graphql"
  @openapi_path "contracts/openapi.json"

  @doc """
  Returns `{repository_relative_path, content}` for every exported contract.
  """
  @spec render_all() :: [{String.t(), binary()}]
  def render_all do
    [
      {@graphql_path, render_graphql_schema()},
      {@openapi_path, render_openapi_document()}
    ]
  end

  defp render_graphql_schema do
    Absinthe.Schema.to_sdl(Schema)
  end

  defp render_openapi_document do
    :bfw_engine
    |> Application.app_dir("priv/openapi/spec.yaml")
    |> YamlElixir.read_from_file!()
    |> sort_keys()
    |> Jason.encode!(pretty: true)
    |> Kernel.<>("\n")
  end

  defp sort_keys(map) when is_map(map) do
    sorted_pairs =
      map
      |> Enum.sort_by(fn {key, _value} -> key end)
      |> Enum.map(fn {key, value} -> {key, sort_keys(value)} end)

    Jason.OrderedObject.new(sorted_pairs)
  end

  defp sort_keys(list) when is_list(list), do: Enum.map(list, &sort_keys/1)
  defp sort_keys(value), do: value
end
