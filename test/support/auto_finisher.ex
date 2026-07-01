defmodule EvilEngine.Test.AutoFinisher do
  @moduledoc """
  EventSink that automatically finishes User Tasks as they become available.

  Used by execution load tests to simulate an API consumer that immediately
  completes every user task. Registers on the EngineEventBus and listens
  for `UserTaskCreated` events, then spawns a fire-and-forget task that
  calls `Execution.finish_user_task/4` with a dummy result.
  """

  @behaviour EvilEngine.Plugin.EventSink

  alias EvilEngine.Types.Event.UserTaskCreated

  @default_identity %EvilEngine.Types.Identity{
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
  def handle_event(%UserTaskCreated{} = event, state) do
    Task.start(fn ->
      EvilEngine.Execution.finish_user_task(
        event.process_instance_id,
        event.flow_node_instance_id,
        @default_result,
        @default_identity
      )
    end)

    {:ok, state}
  end

  @impl true
  def handle_shutdown(_state), do: :ok
end
