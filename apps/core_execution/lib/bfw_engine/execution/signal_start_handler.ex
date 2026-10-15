defmodule BfwEngine.Execution.SignalStartHandler do
  @moduledoc """
  Callback module for `SignalPublisher`'s true-broadcast logic.

  Registered as `{__MODULE__, :start_processes_for_signal}` in the
  `:signal_start_event_handler` config. When a signal is published,
  the publisher always calls this (simultaneously with subscription
  delivery) to find deployed Signal Start Events and start new PIs.

  Unlike `MessageStartHandler`, there is no catch-wins-over-Start
  gating — signals are true broadcast. Start events fire alongside
  catch/boundary events.

  ## Dependency direction

  `core_events` -> (config callback) -> `core_execution` + `core_bpmn`.
  This avoids `core_events` depending on `core_execution`.
  """

  alias BfwEngine.BPMN.ModelCache
  alias BfwEngine.Types.Identity

  alias BfwEngine.Execution.StartEventDiscovery
  alias BfwEngine.Execution.UuidV7

  require Logger

  @doc """
  Find the deployed Signal Start Events matching `signal_name` and start
  at most one PI per enabled process, on its latest live version (see
  `StartEventDiscovery`), with empty payload.

  `triggerer_fni_id` is the FNI ID of the throwing event (Signal Throw or
  Signal End Event) that published the signal, or `nil` when published from
  a REST/plugin source.

  Returns `{:ok, [process_instance_id]}`.
  """
  @spec start_processes_for_signal(String.t(), String.t() | nil) :: {:ok, [String.t()]}
  def start_processes_for_signal(signal_name, triggerer_fni_id \\ nil) do
    matching_starts =
      signal_name
      |> ModelCache.find_signal_start_events()
      |> StartEventDiscovery.latest_live_starts()

    started_ids =
      Enum.flat_map(matching_starts, fn {process_id, process_version_id, start_event_id} ->
        process_instance_id = UuidV7.generate()

        case start_process_from_signal(
               process_instance_id,
               process_version_id,
               start_event_id,
               triggerer_fni_id
             ) do
          {:ok, _pid} ->
            Logger.info(
              "SignalStartHandler: started PI #{process_instance_id} from " <>
                "Signal Start Event #{start_event_id} in process #{process_id}"
            )

            [process_instance_id]

          error ->
            Logger.warning(
              "SignalStartHandler: failed to start PI from Signal Start Event " <>
                "#{start_event_id} in process #{process_id}: #{inspect(error)}"
            )

            []
        end
      end)

    {:ok, started_ids}
  end

  defp start_process_from_signal(
         process_instance_id,
         process_version_id,
         start_event_id,
         triggerer_fni_id
       ) do
    identity = %Identity{
      id: "system:signal_trigger",
      roles: ["system"],
      groups: []
    }

    BfwEngine.Execution.start_process_instance(%{
      process_version_id: process_version_id,
      start_event_id: start_event_id,
      payload: %{},
      identity: identity,
      process_instance_id: process_instance_id,
      triggerer_flow_node_instance_id: triggerer_fni_id
    })
  end
end
