defmodule BfwEngine.Client.Processes do
  @moduledoc """
  Process catalog operations: listing deployed processes and starting new
  process instances.
  """

  alias BfwEngine.Client
  alias BfwEngine.Client.Error
  alias BfwEngine.Client.Wire

  @doc """
  Lists all deployed processes.

  Each entry carries the latest cached version's metadata (`id`,
  `versionId`, `definitionsId`, `version`, `name`, `enabled`, `deployedAt`);
  processes with no cached latest version are omitted by the Engine.
  """
  @spec list(Client.t()) :: {:ok, [map()]} | {:error, Error.t() | Exception.t()}
  def list(%Client{} = client) do
    Client.request(client, :get, "/processes")
  end

  @doc """
  Starts a new instance of the given process model.

  Always resolves to the latest non-deleted, enabled version — there is no
  version pin on start.

  ## Options

    * `:start_event_id` - which Start Event to begin at. Required when the
      process has multiple untyped Start Events.
    * `:payload` - the initial token payload. Defaults to `%{}` on the wire.
    * `:context` - immutable process-level context, available unchanged for
      the whole process instance lifetime.
    * `:business_key` - a business key stamped onto the process instance.
  """
  @spec start(Client.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, Error.t() | Exception.t()}
  def start(%Client{} = client, process_model_id, options \\ []) do
    body =
      %{}
      |> Wire.put_if_present("startEventId", Keyword.get(options, :start_event_id))
      |> Wire.put_if_present("payload", Keyword.get(options, :payload))
      |> Wire.put_if_present("context", Keyword.get(options, :context))
      |> Wire.put_if_present("businessKey", Keyword.get(options, :business_key))

    Client.request(client, :post, "/processes/#{Wire.path_segment(process_model_id)}/start",
      json: body
    )
  end
end
