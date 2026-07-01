defmodule EvilEngine.Execution.MessageStartHandler do
  @moduledoc """
  Callback module for `MessagePublisher`'s catch-wins-over-Start gating.

  Registered as `{__MODULE__, :start_processes_for_message}` in the
  `:message_start_event_handler` config. When a published message has
  no active subscriptions, the publisher calls this to find deployed
  Message Start Events and start new PIs.

  ## Dependency direction

  `core_events` → (config callback) → `core_execution` + `core_bpmn`.
  This avoids `core_events` depending on `core_execution`.
  """

  alias EvilEngine.BPMN.ModelCache
  alias EvilEngine.Types.Identity

  require Logger

  @doc """
  Find all deployed Message Start Events matching `message_name` and
  start one PI per match.

  `triggerer_fni_id` is the FNI ID of the throwing event (Send Task,
  Message End Event, Message Intermediate Throw Event) that published the
  message, or `nil` when published from a REST/plugin source.

  Returns `{:ok, [process_instance_id]}`.
  """
  @spec start_processes_for_message(String.t(), map(), String.t() | nil) :: {:ok, [String.t()]}
  def start_processes_for_message(message_name, payload, triggerer_fni_id \\ nil) do
    matching_starts = ModelCache.find_message_start_events(message_name)

    started_ids =
      Enum.flat_map(matching_starts, fn {process_id, process_version_id, start_event_id} ->
        process_instance_id = generate_id()

        case start_process_from_message(
               process_instance_id,
               process_version_id,
               start_event_id,
               payload,
               triggerer_fni_id
             ) do
          {:ok, _pid} ->
            Logger.info(
              "MessageStartHandler: started PI #{process_instance_id} from " <>
                "Message Start Event #{start_event_id} in process #{process_id}"
            )

            [process_instance_id]

          error ->
            Logger.warning(
              "MessageStartHandler: failed to start PI from Message Start Event " <>
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

  defp start_process_from_message(
         process_instance_id,
         process_version_id,
         start_event_id,
         payload,
         triggerer_fni_id
       ) do
    identity = %Identity{
      id: "system:message_trigger",
      roles: ["system"],
      groups: []
    }

    EvilEngine.Execution.start_process_instance(%{
      process_version_id: process_version_id,
      start_event_id: start_event_id,
      payload: payload,
      identity: identity,
      process_instance_id: process_instance_id,
      triggerer_flow_node_instance_id: triggerer_fni_id
    })
  end
end
