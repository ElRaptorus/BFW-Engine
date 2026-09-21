defmodule IncidentReporter.EventSink do
  @moduledoc """
  EventSink that publishes incident reports when a Process Instance
  transitions to a terminal failure state (`fatal` or `aborted`).

  The sink serializes a structured JSON payload and publishes it to the
  configured message bus exchange. External incident management systems
  (PagerDuty, OpsGenie, custom dashboards) consume these messages and
  may trigger automated or manual remediation — including retry commands
  sent back through the `RetryConsumer`.

  The payload contains enough context for triage without requiring a
  follow-up API call. Systems needing full error details can query
  `GET /process-instances/{id}` (which includes `error_info`).
  """

  @behaviour BfwEngine.Plugin.EventSink

  require Logger

  alias BfwEngine.Types.Event

  @impl true
  def init(opts) do
    message_bus_adapter = Keyword.fetch!(opts, :message_bus_adapter)
    connection = Keyword.fetch!(opts, :connection)
    publish_exchange = Keyword.fetch!(opts, :publish_exchange)

    {:ok,
     %{
       message_bus_adapter: message_bus_adapter,
       connection: connection,
       publish_exchange: publish_exchange,
       incidents_published: 0
     }}
  end

  @impl true
  def accepts?(%Event.ProcessInstanceStateChanged{new_state: state})
      when state in [:fatal, :aborted],
      do: true

  def accepts?(_event), do: false

  @impl true
  def handle_event(%Event.ProcessInstanceStateChanged{} = event, state) do
    incident_payload = build_incident_payload(event)
    encoded_payload = Jason.encode!(incident_payload)

    case state.message_bus_adapter.publish(
           state.connection,
           state.publish_exchange,
           encoded_payload
         ) do
      :ok ->
        Logger.info(
          "incident_reporter: published incident for PI #{event.process_instance_id} " <>
            "(#{event.old_state} → #{event.new_state})"
        )

        {:ok, %{state | incidents_published: state.incidents_published + 1}}

      {:error, reason} ->
        Logger.warning(
          "incident_reporter: failed to publish incident for PI #{event.process_instance_id}: #{inspect(reason)}"
        )

        {:ok, state}
    end
  end

  def handle_event(_event, state), do: {:ok, state}

  @impl true
  def handle_shutdown(state) do
    Logger.info(
      "incident_reporter: shutting down, total incidents published: #{state.incidents_published}"
    )

    :ok
  end

  defp build_incident_payload(%Event.ProcessInstanceStateChanged{} = event) do
    %{
      "type" => "incident",
      "processInstanceId" => event.process_instance_id,
      "processModelId" => event.process_model_id,
      "version" => event.version,
      "parentProcessInstanceId" => event.parent_process_instance_id,
      "previousState" => to_string(event.old_state),
      "newState" => to_string(event.new_state),
      "occurredAt" => DateTime.to_iso8601(DateTime.utc_now())
    }
  end
end
