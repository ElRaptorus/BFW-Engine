defmodule BfwEngine.Client.ManualTasks do
  @moduledoc """
  Manual Task lifecycle: confirming or cancelling a waiting Manual Task
  (`bfw:requireConfirmation` set). Waiting Manual Tasks are listed by
  `BfwEngine.Client.UserTasks.list_waiting/2`.
  """

  alias BfwEngine.Client
  alias BfwEngine.Client.Error
  alias BfwEngine.Client.Wire

  @doc """
  Confirms a waiting Manual Task.

  The request has no body: the token the Manual Task entered with continues
  unchanged. The Engine responds `204 No Content`, so the success value is
  the empty body `""` — there is no JSON to decode.
  """
  @spec confirm(Client.t(), String.t()) ::
          {:ok, String.t()} | {:error, Error.t() | Exception.t()}
  def confirm(%Client{} = client, flow_node_instance_id) do
    Client.request(
      client,
      :put,
      "/manual-tasks/#{Wire.path_segment(flow_node_instance_id)}/confirm"
    )
  end

  @doc """
  Cancels a waiting Manual Task, which aborts the whole process instance tree.

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
      "/manual-tasks/#{Wire.path_segment(flow_node_instance_id)}/cancel",
      json: body
    )
  end
end
