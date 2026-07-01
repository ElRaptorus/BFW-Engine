defmodule EvilEngine.Execution.SignalStartHandler do
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

  alias EvilEngine.BPMN.ModelCache
  alias EvilEngine.Types.Identity

  require Logger

  @doc """
  Find all deployed Signal Start Events matching `signal_name` and
  start one PI per match with empty payload.

  `triggerer_fni_id` is the FNI ID of the throwing event (Signal Throw or
  Signal End Event) that published the signal, or `nil` when published from
  a REST/plugin source.

  Returns `{:ok, [process_instance_id]}`.
  """
  @spec start_processes_for_signal(String.t(), String.t() | nil) :: {:ok, [String.t()]}
  def start_processes_for_signal(signal_name, triggerer_fni_id \\ nil) do
    matching_starts = ModelCache.find_signal_start_events(signal_name)

    started_ids =
      Enum.flat_map(matching_starts, fn {process_id, process_version_id, start_event_id} ->
        process_instance_id = generate_id()

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

  defp generate_id do
    timestamp_ms = System.system_time(:millisecond)
    <<rand_a::12, rand_b::62, _::6>> = :crypto.strong_rand_bytes(10)

    <<timestamp_ms::48, 7::4, rand_a::12, 2::2, rand_b::62>>
    |> Base.encode16(case: :lower)
    |> then(fn <<a::binary-8, b::binary-4, c::binary-4, d::binary-4, e::binary-12>> ->
      "#{a}-#{b}-#{c}-#{d}-#{e}"
    end)
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

    EvilEngine.Execution.start_process_instance(%{
      process_version_id: process_version_id,
      start_event_id: start_event_id,
      payload: %{},
      identity: identity,
      process_instance_id: process_instance_id,
      triggerer_flow_node_instance_id: triggerer_fni_id
    })
  end
end
