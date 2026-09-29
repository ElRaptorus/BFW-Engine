defmodule BfwEngine.Test.AutoFinisher do
  @moduledoc """
  EventSink that automatically finishes inbox tasks as they become available.

  Used by execution load tests to simulate an API consumer that immediately
  completes every waiting User Task or confirming Manual Task. Registers on
  the EngineEventBus and listens for `UserTaskCreated` events, then spawns a
  task that retries `Execution.finish_user_task/4` or
  `Execution.confirm_manual_task/3` until the flow node instance is waiting.
  """

  @behaviour BfwEngine.Plugin.EventSink

  alias BfwEngine.Test.AsyncCompletionRetry
  alias BfwEngine.Types.Event.UserTaskCreated

  @default_identity %BfwEngine.Types.Identity{
    id: "auto-finisher",
    roles: ["admin"],
    groups: []
  }

  @default_result %{"auto_finished" => true}

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def accepts?(%UserTaskCreated{}), do: true
  def accepts?(_event), do: false

  @impl true
  def handle_event(%UserTaskCreated{flow_node_type: :manual_task} = event, state) do
    Task.start(fn ->
      AsyncCompletionRetry.until_ok(fn ->
        BfwEngine.Execution.confirm_manual_task(
          event.process_instance_id,
          event.flow_node_instance_id,
          @default_identity
        )
      end)
    end)

    {:ok, state}
  end

  def handle_event(%UserTaskCreated{} = event, state) do
    Task.start(fn ->
      AsyncCompletionRetry.until_ok(fn ->
        BfwEngine.Execution.finish_user_task(
          event.process_instance_id,
          event.flow_node_instance_id,
          @default_result,
          @default_identity
        )
      end)
    end)

    {:ok, state}
  end

  @impl true
  def handle_shutdown(_state), do: :ok
end
