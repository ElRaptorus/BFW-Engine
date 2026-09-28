defmodule BfwEngine.Client.UserTasks do
  @moduledoc """
  User Task and Manual Task lifecycle: listing the pending inbox, and
  finishing or cancelling a task.
  """

  alias BfwEngine.Client
  alias BfwEngine.Client.Error
  alias BfwEngine.Client.Graphql
  alias BfwEngine.Client.Wire

  @list_waiting_document """
  query ListWaitingUserTasks($state: String, $flowNodeTypeIn: [String!], $limit: Int, $offset: Int) {
    flowNodeInstances(
      filter: { state: { eq: $state }, flowNodeType: { in: $flowNodeTypeIn } }
      limit: $limit
      offset: $offset
    ) {
      results {
        id
        flowNodeId
        flowNodeType
        state
        typeProperties
      }
    }
  }
  """

  @waiting_flow_node_types ["user_task", "manual_task"]

  @doc """
  Lists waiting User Tasks and Manual Tasks.

  Each result carries `typeProperties`, passed through exactly as the Engine
  stored it. For User Tasks, `typeProperties["form_schema"]` holds the
  `bfw:formFields` schema and `typeProperties["form_actions"]` the available
  actions.

  ## Options

    * `:limit` - page size passed to `flowNodeInstances`.
    * `:offset` - page offset passed to `flowNodeInstances`.
  """
  @spec list_waiting(Client.t(), keyword()) ::
          {:ok, [map()]} | {:error, Error.t() | Exception.t()}
  def list_waiting(%Client{} = client, options \\ []) do
    variables =
      %{"state" => "waiting", "flowNodeTypeIn" => @waiting_flow_node_types}
      |> maybe_page(options)

    case Graphql.query(client, @list_waiting_document, variables) do
      {:ok, %{"flowNodeInstances" => %{"results" => results}}} ->
        {:ok, Enum.map(results, &Wire.normalize_flow_node_instance/1)}

      other ->
        other
    end
  end

  defp maybe_page(variables, options) do
    variables
    |> maybe_put_page("limit", Keyword.get(options, :limit))
    |> maybe_put_page("offset", Keyword.get(options, :offset))
  end

  defp maybe_put_page(variables, _key, nil), do: variables
  defp maybe_put_page(variables, key, value), do: Map.put(variables, key, value)

  @doc """
  Finishes a waiting User Task or Manual Task (with `bfw:requireConfirmation`
  set), completing it with the given result.

  The Engine responds `204 No Content`, so the success value is the empty
  body `""` — there is no JSON to decode.

  ## Options

    * `:result` - the outcome payload. Defaults to `%{}` on the wire.
  """
  @spec finish(Client.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, Error.t() | Exception.t()}
  def finish(%Client{} = client, flow_node_instance_id, options \\ []) do
    body = Wire.put_if_present(%{}, "result", Keyword.get(options, :result))

    Client.request(
      client,
      :put,
      "/user-tasks/#{Wire.path_segment(flow_node_instance_id)}/finish",
      json: body
    )
  end

  @doc """
  Cancels a waiting User Task or Manual Task.

  The Engine responds `204 No Content`, so the success value is the empty
  body `""` — there is no JSON to decode.

  ## Options

    * `:reason` - an optional human-readable cancel reason.
  """
  @spec cancel(Client.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, Error.t() | Exception.t()}
  def cancel(%Client{} = client, flow_node_instance_id, options \\ []) do
    body = Wire.put_if_present(%{}, "reason", Keyword.get(options, :reason))

    Client.request(
      client,
      :put,
      "/user-tasks/#{Wire.path_segment(flow_node_instance_id)}/cancel",
      json: body
    )
  end
end
