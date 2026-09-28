defmodule BfwEngine.Client.ProcessInstances do
  @moduledoc """
  Process instance lifecycle: reading state, aborting, and listing
  waiting catch-side flow node instances.
  """

  alias BfwEngine.Client
  alias BfwEngine.Client.Error
  alias BfwEngine.Client.Graphql
  alias BfwEngine.Client.Wire

  @get_process_instance_document """
  query GetProcessInstance($id: ID!) {
    getProcessInstance(id: $id) {
      id
      state
      processVersion {
        version
      }
      startedAt
      finishedAt
    }
  }
  """

  @waiting_catches_document """
  query WaitingCatches($processInstanceId: ID, $state: String, $flowNodeTypeIn: [String!], $limit: Int, $offset: Int) {
    flowNodeInstances(
      filter: {
        processInstanceId: { eq: $processInstanceId },
        state: { eq: $state },
        flowNodeType: { in: $flowNodeTypeIn }
      }
      limit: $limit
      offset: $offset
    ) {
      results {
        id
        flowNodeId
        flowNodeType
        eventType
        state
        typeProperties
      }
    }
  }
  """

  @waiting_catch_flow_node_types ["intermediate_catch_event", "boundary_event", "receive_task"]

  @doc """
  Fetches a process instance's state, version, and timestamps.
  """
  @spec get(Client.t(), String.t()) :: {:ok, map()} | {:error, Error.t() | Exception.t()}
  def get(%Client{} = client, process_instance_id) do
    case Graphql.query(client, @get_process_instance_document, %{"id" => process_instance_id}) do
      {:ok, %{"getProcessInstance" => nil}} ->
        {:error, %Error{status: 404, code: "not_found", reason: :not_found, message: "not found"}}

      {:ok, %{"getProcessInstance" => process_instance}} ->
        {:ok, process_instance}

      other ->
        other
    end
  end

  @doc """
  Aborts a process instance. This is a tree-wide kill switch: aborting any
  process instance in a process tree aborts the entire tree.

  The Engine responds `204 No Content`, so the success value is the empty
  body `""` — there is no JSON to decode.

  ## Options

    * `:reason` - an optional human-readable abort reason.
  """
  @spec abort(Client.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, Error.t() | Exception.t()}
  def abort(%Client{} = client, process_instance_id, options \\ []) do
    body = Wire.put_if_present(%{}, "reason", Keyword.get(options, :reason))

    Client.request(
      client,
      :put,
      "/process-instances/#{Wire.path_segment(process_instance_id)}/abort",
      json: body
    )
  end

  @doc """
  Lists the waiting catch-side flow node instances (Intermediate Catch,
  Boundary, Receive Task) for a process instance.

  Each result carries `typeProperties`, an untyped JSON map passed through
  exactly as the Engine stored it (handler keys such as `message_name` or
  `fire_at` are not camelized).

  ## Options

    * `:limit` - page size passed to `flowNodeInstances`.
    * `:offset` - page offset passed to `flowNodeInstances`.
  """
  @spec waiting_catches(Client.t(), String.t(), keyword()) ::
          {:ok, [map()]} | {:error, Error.t() | Exception.t()}
  def waiting_catches(%Client{} = client, process_instance_id, options \\ []) do
    variables =
      %{
        "processInstanceId" => process_instance_id,
        "state" => "waiting",
        "flowNodeTypeIn" => @waiting_catch_flow_node_types
      }
      |> maybe_page(options)

    case Graphql.query(client, @waiting_catches_document, variables) do
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
end
