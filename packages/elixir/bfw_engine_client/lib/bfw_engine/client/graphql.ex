defmodule BfwEngine.Client.Graphql do
  @moduledoc """
  Raw GraphQL access (`POST /api/v1/graphql`).

  Resource modules that read process instances and flow node instances
  (`BfwEngine.Client.ProcessInstances`, `BfwEngine.Client.UserTasks`) build
  their documents as module attributes and call `query/3` internally,
  but it is also exposed directly for callers who need a custom query.

  Filter and sort values are plain strings on this wire (state `"waiting"`,
  flow node type `"user_task"`, and so on) — never GraphQL enums.
  """

  alias BfwEngine.Client
  alias BfwEngine.Client.Error

  @doc """
  Executes a GraphQL document against the Engine.

  Returns `{:ok, data}` with the `data` object of the response on success.
  When the response carries a top-level `errors[]` array, the first entry is
  mapped through `BfwEngine.Client.Error.from_graphql_error/1` and returned
  as `{:error, error}` — the same shape as a REST failure.
  """
  @spec query(Client.t(), String.t(), map()) :: {:ok, map()} | {:error, Error.t() | Exception.t()}
  def query(%Client{} = client, document, variables \\ %{}) do
    body = %{"query" => document, "variables" => variables}

    case Client.request(client, :post, "/api/v1/graphql", json: body) do
      {:ok, %{"errors" => [first_error | _remaining_errors]}} ->
        {:error, Error.from_graphql_error(first_error)}

      {:ok, %{"data" => data}} ->
        {:ok, data}

      {:error, _reason} = error ->
        error
    end
  end
end
