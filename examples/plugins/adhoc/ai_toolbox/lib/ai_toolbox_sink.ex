defmodule Examples.Plugins.Adhoc.AiToolbox.AiToolboxSink do
  @moduledoc """
  Drives a plugin-managed Ad-hoc Sub-Process by picking the next tool to
  activate from a static priority list, standing in for a real LLM/reasoning
  call. See `README.md` for the full scenario.

  Registration: `facade.register_event_sink.("ai-toolbox", __MODULE__, facade: facade)`
  """

  @behaviour BfwEngine.Plugin.EventSink

  require Logger

  alias BfwEngine.Types.Event

  @tool_priority ["LookupOrder", "CheckInventory", "CreateTicket", "SendEmail", "EscalateToHuman"]
  @max_tools_per_inquiry 3

  @doc "Initializes empty per-scope tracking state from the injected facade."
  @impl true
  def init(options) do
    facade = Keyword.fetch!(options, :facade)
    {:ok, %{facade: facade, scopes: %{}}}
  end

  @doc "Accepts ad-hoc scope starts, inner-activity completions, and ad-hoc scope completions."
  @impl true
  def accepts?(%Event.SubProcessChildStarted{is_ad_hoc_subprocess: true}), do: true
  def accepts?(%Event.FlowNodeInstanceFinished{}), do: true
  def accepts?(%Event.AdHocSubProcessCompleted{}), do: true
  def accepts?(_event), do: false

  @doc "Picks and activates the first tool when a new ad-hoc scope starts; reacts to tool completions; forgets finished scopes."
  @impl true
  def handle_event(
        %Event.SubProcessChildStarted{is_ad_hoc_subprocess: true} = event,
        state
      ) do
    scopes = Map.put(state.scopes, event.child_process_instance_id, [])
    {:ok, pick_and_activate(event.child_process_instance_id, %{state | scopes: scopes})}
  end

  def handle_event(
        %Event.FlowNodeInstanceFinished{terminal_state: :finished} = event,
        %{scopes: scopes} = state
      ) do
    if Map.has_key?(scopes, event.process_instance_id) do
      {:ok, handle_tool_finished(event.process_instance_id, event.flow_node_id, state)}
    else
      {:ok, state}
    end
  end

  def handle_event(%Event.AdHocSubProcessCompleted{} = event, state) do
    {:ok, %{state | scopes: Map.delete(state.scopes, event.process_instance_id)}}
  end

  def handle_event(_event, state), do: {:ok, state}

  @doc "No cleanup needed on shutdown -- ad-hoc scopes outlive this sink and are tracked engine-side regardless."
  @impl true
  def handle_shutdown(_state), do: :ok

  defp handle_tool_finished(child_process_instance_id, "EscalateToHuman", state) do
    complete_scope(child_process_instance_id, state)
  end

  defp handle_tool_finished(child_process_instance_id, flow_node_id, state) do
    performed = [flow_node_id | Map.get(state.scopes, child_process_instance_id, [])]
    state = put_in(state.scopes[child_process_instance_id], performed)

    if length(performed) >= @max_tools_per_inquiry do
      complete_scope(child_process_instance_id, state)
    else
      pick_and_activate(child_process_instance_id, state)
    end
  end

  defp pick_and_activate(child_process_instance_id, state) do
    performed = Map.get(state.scopes, child_process_instance_id, [])

    case state.facade.adhoc_subprocesses.get_enabled_activities.(child_process_instance_id) do
      {:ok, activities} ->
        case choose_next_tool(activities, performed) do
          nil ->
            complete_scope(child_process_instance_id, state)

          tool_id ->
            case state.facade.adhoc_subprocesses.activate_activity.(
                   child_process_instance_id,
                   tool_id
                 ) do
              {:ok, _result} ->
                state

              {:error, reason} ->
                Logger.error(
                  "ai_toolbox activate_activity failed scope=#{child_process_instance_id} tool=#{tool_id} reason=#{inspect(reason)}"
                )

                state
            end
        end

      {:error, reason} ->
        Logger.error(
          "ai_toolbox get_enabled_activities failed scope=#{child_process_instance_id} reason=#{inspect(reason)}"
        )

        state
    end
  end

  defp complete_scope(child_process_instance_id, state) do
    case state.facade.adhoc_subprocesses.complete.(child_process_instance_id) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error(
          "ai_toolbox complete failed scope=#{child_process_instance_id} reason=#{inspect(reason)}"
        )
    end

    state
  end

  @doc false
  @spec choose_next_tool([map()], [String.t()]) :: String.t() | nil
  def choose_next_tool(activities, already_performed) do
    enabled_ids =
      activities
      |> Enum.filter(& &1.enabled)
      |> Enum.map(& &1.id)

    @tool_priority
    |> Enum.reject(&(&1 in already_performed))
    |> Enum.find(&(&1 in enabled_ids))
  end
end
