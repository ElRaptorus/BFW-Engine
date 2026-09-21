defmodule Examples.Plugins.Combined.RabbitmqToEngine.OrchestratorMetricsSink do
  @moduledoc """
  Event sink that tracks orchestration-related notifications: engine process
  instance lifecycle plus custom `OrchestratorCustomEvent` payloads.
  """

  @behaviour BfwEngine.Plugin.EventSink

  require Logger

  alias BfwEngine.Types.Event
  alias Examples.Plugins.Combined.RabbitmqToEngine.OrchestratorCustomEvent

  @doc "Initializes per-event counters for orchestrator custom events and process instance state changes."
  @impl true
  def init(_options), do: {:ok, %{orchestrator_dispatches: 0, process_instance_state_events: 0}}

  @doc "Returns true only for process instance lifecycle, custom orchestrator, and rejects all other events."
  @impl true
  def accepts?(%Event.ProcessInstanceStateChanged{}), do: true

  @impl true
  def accepts?(%OrchestratorCustomEvent{}), do: true

  @impl true
  def accepts?(_event), do: false

  @doc "Updates counters and logs for orchestrator custom events, state changes, or passes through unexpectedly routed events."
  @impl true
  def handle_event(%OrchestratorCustomEvent{} = event, state) do
    updated_state = %{state | orchestrator_dispatches: state.orchestrator_dispatches + 1}

    Logger.info(
      "orchestrator_metrics: orchestrator_dispatches=#{updated_state.orchestrator_dispatches} type=#{inspect(event.type)} process_model_id=#{event.process_model_id}"
    )

    {:ok, updated_state}
  end

  @impl true
  def handle_event(%Event.ProcessInstanceStateChanged{} = event, state) do
    updated_state = %{
      state
      | process_instance_state_events: state.process_instance_state_events + 1
    }

    Logger.info(
      "orchestrator_metrics: process_instance_state_events=#{updated_state.process_instance_state_events} process_instance_id=#{event.process_instance_id} new_state=#{inspect(event.new_state)}"
    )

    {:ok, updated_state}
  end

  @impl true
  def handle_event(_event, state), do: {:ok, state}

  @doc "Logs the final orchestration counters when the sink worker shuts down."
  @impl true
  def handle_shutdown(state) do
    Logger.info(
      "orchestrator_metrics: shutdown orchestrator_dispatches=#{state.orchestrator_dispatches} process_instance_state_events=#{state.process_instance_state_events}"
    )

    :ok
  end
end
