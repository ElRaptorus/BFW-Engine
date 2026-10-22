defmodule BfwEngine.Execution.StartEventDiscovery do
  @moduledoc """
  Decides which indexed start events a message start, signal start, or
  cycle timer fire may start.

  A candidate starts only when its process is enabled and its version is
  the process's latest live version, the same resolution as
  `POST /processes/{id}/start`. At most one candidate per process survives,
  so one publish or fire creates at most one instance per process.
  """

  alias BfwEngine.Execution.CalledElementResolver

  require Logger

  @type candidate ::
          {process_model_id :: String.t(), process_version_id :: String.t(),
           start_event_id :: String.t()}

  @doc "Keep the first candidate of each process whose version is the latest live version."
  @spec latest_live_starts([candidate()]) :: [candidate()]
  def latest_live_starts(candidates) do
    candidates
    |> Enum.group_by(fn {process_model_id, _version_id, _start_event_id} -> process_model_id end)
    |> Enum.flat_map(fn {process_model_id, process_candidates} ->
      case resolve_latest_version_id(process_model_id) do
        {:ok, latest_version_id} ->
          process_candidates
          |> Enum.filter(&(elem(&1, 1) == latest_version_id))
          |> Enum.take(1)

        :none ->
          []
      end
    end)
  end

  @doc "True when `process_version_id` is the latest live version of an enabled process."
  @spec latest_live_version?(String.t(), String.t()) :: boolean()
  def latest_live_version?(process_model_id, process_version_id) do
    resolve_latest_version_id(process_model_id) == {:ok, process_version_id}
  end

  defp resolve_latest_version_id(process_model_id) do
    case CalledElementResolver.adapter().resolve_latest_version(process_model_id) do
      {:ok, %{process_version_id: version_id}} ->
        {:ok, version_id}

      {:error, reason} ->
        Logger.info(
          "StartEventDiscovery: process #{process_model_id} has no startable version " <>
            "(#{inspect(reason)}); its start events are skipped"
        )

        :none
    end
  end
end
