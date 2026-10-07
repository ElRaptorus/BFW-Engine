defmodule BfwEngine.Execution.TaskInboxEvents do
  @moduledoc """
  Single emission point for the task inbox events (`UserTaskCreated`,
  `UserTaskFinished`).

  A User Task or a confirming Manual Task (`bfw:requireConfirmation="true"`)
  is an "inbox task" — it waits for an external actor to act on it. Every
  `FlowNodeInstanceFinished` publish in `core_execution` must go through
  `publish_flow_node_instance_finished/3` so that `UserTaskFinished` is
  derived consistently, regardless of which path ended the inbox task
  (explicit finish/cancel, boundary interrupt, Terminate/Error/Cancel End,
  Complex-Join region cancel, PI abort, fatal, or error cascade).

  `UserTaskFinished` is published only when the flow node is an inbox task,
  it is not the multi-instance or standard-loop shell, and either the
  terminal state is `:finished` or the caller passes `was_waiting: true`.
  A task that never reached `waiting` does not get a withdrawal event.
  """

  alias BfwEngine.BPMN.Model.FlowNode
  alias BfwEngine.Events.EngineEventBus
  alias BfwEngine.Execution.HandlerContext
  alias BfwEngine.Execution.ProcessInstance.LaneResolution
  alias BfwEngine.Types.Event

  @doc """
  Returns whether `flow_node` is an inbox task: a User Task, or a Manual
  Task with `bfw:requireConfirmation` set to `true`.
  """
  @spec inbox_task?(FlowNode.t() | nil) :: boolean()
  def inbox_task?(nil), do: false
  def inbox_task?(%FlowNode{type: :user_task}), do: true

  def inbox_task?(%FlowNode{type: :manual_task, type_data: %{require_confirmation: true}}),
    do: true

  def inbox_task?(%FlowNode{}), do: false

  @doc """
  Publishes `UserTaskCreated` for an inbox task entering `waiting` state.

  Manual Task callers pass `assignees: []` — Manual Tasks have no
  `bfw:assignees` extension.
  """
  @spec publish_created(HandlerContext.t(), FlowNode.t(), [String.t()]) :: :ok
  def publish_created(context, flow_node, assignees) do
    EngineEventBus.publish(%Event.UserTaskCreated{
      flow_node_instance_id: context.flow_node_instance_id,
      process_instance_id: context.process_instance_id,
      root_process_instance_id: context.root_process_instance_id,
      flow_node_id: flow_node.id,
      flow_node_type: flow_node.type,
      assignees: assignees,
      lane_name: LaneResolution.resolve_lane_name_from_context(context, flow_node),
      occurred_at: DateTime.utc_now()
    })

    :ok
  end

  @doc """
  Publishes a `FlowNodeInstanceFinished` event and, when the finishing flow
  node is an inbox task, derives and publishes the matching `UserTaskFinished`.

  This is the only place in `core_execution` allowed to call
  `EngineEventBus.publish/1` with a `%Event.FlowNodeInstanceFinished{}`
  struct — every other call site must go through this function, passing
  the flow node it already has at hand (`nil` when unavailable, e.g. a
  crash fallback before the handler ran).

  The terminal state maps to the outcome: `:finished` becomes `:completed`,
  every other terminal state (`:aborted`, `:interrupted`, `:error`,
  `:fatal`) becomes `:aborted` — a waiting inbox task that does not reach
  `:finished` was withdrawn from the inbox, regardless of why.

  MI/Standard Loop **shell** FNIs are skipped (the shell itself is never an
  inbox item; only its iteration FNIs are). A shell is identified by the
  flow node carrying `multi_instance` or `standard_loop` characteristics
  while the finished event has no `iteration_index`.

  Options:

  - `:was_waiting` — whether this flow node instance had reached `waiting`
    before the terminal write. Defaults to `true` only when
    `terminal_state` is `:finished` (completion runs after waiting). Every
    other terminal state requires the caller to pass the flag. A
    `UserTaskFinished` is published only for `:finished` or `was_waiting: true`.
  """
  @spec publish_flow_node_instance_finished(
          Event.FlowNodeInstanceFinished.t(),
          FlowNode.t() | nil,
          keyword()
        ) ::
          :ok
  def publish_flow_node_instance_finished(event, flow_node, opts \\ [])

  def publish_flow_node_instance_finished(
        %Event.FlowNodeInstanceFinished{} = event,
        flow_node,
        opts
      ) do
    EngineEventBus.publish(event)

    was_waiting = Keyword.get(opts, :was_waiting, event.terminal_state == :finished)

    if inbox_task?(flow_node) and not shell_finished?(flow_node, event) and
         (event.terminal_state == :finished or was_waiting) do
      publish_finished(event, flow_node)
    end

    :ok
  end

  @doc """
  Publishes `event` when the terminal write committed.

  `{:error, :already_terminal}` means a later `:update_finished` lost: the
  row was left unchanged, so nothing is published. Any other error means the
  write did not commit, so nothing is published either.
  """
  @spec publish_committed_finish(
          :ok | {:ok, term()} | {:error, term()},
          Event.FlowNodeInstanceFinished.t(),
          FlowNode.t() | nil
        ) :: :ok
  def publish_committed_finish(:ok, event, flow_node),
    do: publish_written_finish(event, flow_node)

  def publish_committed_finish({:ok, _value}, event, flow_node),
    do: publish_written_finish(event, flow_node)

  def publish_committed_finish({:error, _reason}, _event, _flow_node), do: :ok

  defp publish_written_finish(event, flow_node) do
    publish_flow_node_instance_finished(event, flow_node)
  end

  defp publish_finished(event, flow_node) do
    EngineEventBus.publish(%Event.UserTaskFinished{
      flow_node_instance_id: event.flow_node_instance_id,
      process_instance_id: event.process_instance_id,
      root_process_instance_id: event.root_process_instance_id,
      flow_node_id: event.flow_node_id,
      flow_node_type: flow_node.type,
      outcome: outcome_for(event.terminal_state),
      lane_name: event.lane_name,
      occurred_at: event.occurred_at
    })
  end

  defp shell_finished?(flow_node, event) do
    loop_characteristics?(flow_node) and is_nil(event.iteration_index)
  end

  defp loop_characteristics?(%FlowNode{
         multi_instance: multi_instance,
         standard_loop: standard_loop
       }) do
    not is_nil(multi_instance) or not is_nil(standard_loop)
  end

  defp outcome_for(:finished), do: :completed
  defp outcome_for(_other_terminal_state), do: :aborted
end
