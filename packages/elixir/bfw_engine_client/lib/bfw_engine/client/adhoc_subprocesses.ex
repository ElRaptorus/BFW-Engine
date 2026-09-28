defmodule BfwEngine.Client.AdhocSubprocesses do
  @moduledoc """
  Ad-hoc subprocess control: listing, activating, and completing inner
  activities.

  Every function's `process_instance_id` argument is the **child** process
  instance ID spawned by the ad-hoc subprocess handler — not the parent
  process instance, and not the shell flow node instance.
  """

  alias BfwEngine.Client
  alias BfwEngine.Client.Error
  alias BfwEngine.Client.Wire

  @doc """
  Lists the enabled and performed inner activities.
  """
  @spec activities(Client.t(), String.t()) :: {:ok, [map()]} | {:error, Error.t() | Exception.t()}
  def activities(%Client{} = client, process_instance_id) do
    case Client.request(
           client,
           :get,
           "/adhoc-subprocesses/#{Wire.path_segment(process_instance_id)}/activities"
         ) do
      {:ok, %{"data" => data}} -> {:ok, data}
      other -> other
    end
  end

  @doc """
  Activates an inner activity by its BPMN flow node ID.
  """
  @spec activate(Client.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, Error.t() | Exception.t()}
  def activate(%Client{} = client, process_instance_id, activity_id) do
    Client.request(
      client,
      :post,
      "/adhoc-subprocesses/#{Wire.path_segment(process_instance_id)}/activities/#{Wire.path_segment(activity_id)}/activate"
    )
  end

  @doc """
  Signals completion of the ad-hoc subprocess.
  """
  @spec complete(Client.t(), String.t()) :: {:ok, map()} | {:error, Error.t() | Exception.t()}
  def complete(%Client{} = client, process_instance_id) do
    Client.request(
      client,
      :post,
      "/adhoc-subprocesses/#{Wire.path_segment(process_instance_id)}/complete"
    )
  end

  @doc """
  Queries the ad-hoc subprocess's runtime status.
  """
  @spec status(Client.t(), String.t()) :: {:ok, map()} | {:error, Error.t() | Exception.t()}
  def status(%Client{} = client, process_instance_id) do
    Client.request(
      client,
      :get,
      "/adhoc-subprocesses/#{Wire.path_segment(process_instance_id)}/status"
    )
  end
end
