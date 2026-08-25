defmodule EvilEngineWeb.Ws.EventDelivery do
  @moduledoc """
  Dispatch-time WebSocket authorization for Phoenix Channel event envelopes.

  Filtering happens in the channel process after PubSub broadcast so each
  subscriber applies its own join-cached identity. Classification uses the
  envelope `type` string (explicit allow-lists) rather than field presence:
  JSON `null` and a missing `laneName` are indistinguishable via `get_in/2`.

  `admin_override` is zeeky-only. `observe_all` is a separate unbounded-read
  assign and never implies write bypass.
  """

  @engine_level_types MapSet.new([
                        "EngineStarted",
                        "EngineShutdown",
                        "EngineOverloaded",
                        "EngineRecovered",
                        "PluginQuarantined",
                        "ProcessDefinitionDeployed",
                        "ProcessDefinitionUndeployed",
                        "ProcessDefinitionEnabled",
                        "ProcessDefinitionDisabled",
                        "DecisionDefinitionDeployed",
                        "DecisionDefinitionUndeployed",
                        "DecisionEvaluated",
                        "MessagePublished",
                        "SignalPublished"
                      ])

  @process_instance_level_types MapSet.new([
                                  "ProcessInstanceStateChanged",
                                  "ProcessInstanceRetried"
                                ])

  @pending_user_task_types MapSet.new([
                             "UserTaskCreated",
                             "UserTaskFinished"
                           ])

  @flow_node_originating_types MapSet.new([
                                 "FlowNodeInstanceStarted",
                                 "FlowNodeInstanceFinished",
                                 "FlowNodeInstanceStateChanged",
                                 "MultiInstanceStarted",
                                 "MultiInstanceCompleted",
                                 "UserTaskCreated",
                                 "UserTaskFinished",
                                 "UserTaskValidationFailed",
                                 "PluginAsyncFlowNodeRehydrated",
                                 "CallActivityChildStarted",
                                 "SubProcessChildStarted",
                                 "EventSubprocessTriggered",
                                 "DataObjectWritten",
                                 "TimerFired",
                                 "MessageArrived",
                                 "SignalArrived",
                                 "EscalationRaised",
                                 "CompensationTriggered",
                                 "ActivityCompensated",
                                 "TransactionCancelled",
                                 "AdHocActivityActivated",
                                 "AdHocSubProcessCompleted"
                               ])

  @type assigns :: %{
          optional(:admin_override) => boolean(),
          optional(:observe_all) => boolean(),
          optional(:accessible_lanes) => [String.t()],
          optional(:writable_lanes) => [String.t()],
          optional(:identity_id) => String.t() | nil,
          optional(:topic) => String.t() | nil
        }

  @doc """
  Return whether `payload` should be pushed to the subscriber described by `assigns`.

  `assigns` is expected to contain `:admin_override`, `:observe_all`,
  `:accessible_lanes`, `:identity_id`, and `:topic`. Missing keys are
  treated as the restrictive default.
  """
  @spec should_deliver?(map(), map()) :: boolean()
  def should_deliver?(payload, assigns) when is_map(payload) and is_map(assigns) do
    cond do
      assigns[:admin_override] == true ->
        true

      assigns[:observe_all] == true ->
        true

      pending_user_tasks_topic?(assigns[:topic]) ->
        deliver_pending_user_task?(payload, assigns)

      engine_level?(payload) ->
        true

      process_instance_level?(payload) ->
        deliver_process_instance_level?(payload, assigns)

      flow_node_originating?(payload) ->
        flow_node_lane_accessible?(event_data(payload), assigns)

      true ->
        false
    end
  end

  def should_deliver?(_payload, _assigns), do: false

  @doc """
  Return the three dispatch classification allow-lists as sorted type strings.

  `SinkFailed` is intentionally absent: the WebSocket sink rejects it in
  `accepts?/1`, so it never reaches this filter. Unknown envelope types are
  dropped (`admin_override` and `observe_all` still deliver them).
  """
  @spec classified_types() :: %{
          engine_level: [String.t()],
          process_instance_level: [String.t()],
          flow_node_originating: [String.t()]
        }
  def classified_types do
    %{
      engine_level: @engine_level_types |> MapSet.to_list() |> Enum.sort(),
      process_instance_level: @process_instance_level_types |> MapSet.to_list() |> Enum.sort(),
      flow_node_originating: @flow_node_originating_types |> MapSet.to_list() |> Enum.sort()
    }
  end

  defp deliver_pending_user_task?(payload, assigns) do
    type = event_type(payload)

    if MapSet.member?(@pending_user_task_types, type) do
      flow_node_lane_accessible?(event_data(payload), assigns)
    else
      false
    end
  end

  defp deliver_process_instance_level?(payload, assigns) do
    topic = assigns[:topic] || ""

    cond do
      String.starts_with?(topic, "process_instance:") ->
        true

      topic == "engine:events" ->
        process_instance_visible_on_engine_events?(event_data(payload), assigns)

      true ->
        process_instance_visible_on_engine_events?(event_data(payload), assigns)
    end
  end

  defp process_instance_visible_on_engine_events?(data, assigns) do
    starter_match?(data, assigns) or
      data["hasLanelessFlowNode"] == true or
      any_lane_accessible?(data["laneNames"], assigns)
  end

  defp starter_match?(data, assigns) do
    started_by_id = data["startedById"]
    identity_id = assigns[:identity_id]
    is_binary(started_by_id) and is_binary(identity_id) and started_by_id == identity_id
  end

  defp any_lane_accessible?(lane_names, assigns) when is_list(lane_names) do
    accessible_lanes = assigns[:accessible_lanes] || []
    Enum.any?(lane_names, &(&1 in accessible_lanes))
  end

  defp any_lane_accessible?(_lane_names, _assigns), do: false

  defp flow_node_lane_accessible?(data, assigns) do
    case data["laneName"] do
      nil -> true
      lane_name -> lane_name in (assigns[:accessible_lanes] || [])
    end
  end

  defp engine_level?(payload), do: MapSet.member?(@engine_level_types, event_type(payload))

  defp process_instance_level?(payload),
    do: MapSet.member?(@process_instance_level_types, event_type(payload))

  defp flow_node_originating?(payload),
    do: MapSet.member?(@flow_node_originating_types, event_type(payload))

  defp pending_user_tasks_topic?("user_tasks:pending"), do: true
  defp pending_user_tasks_topic?(_topic), do: false

  defp event_type(%{"type" => type}) when is_binary(type), do: type
  defp event_type(_payload), do: ""

  defp event_data(%{"data" => data}) when is_map(data), do: data
  defp event_data(_payload), do: %{}
end
