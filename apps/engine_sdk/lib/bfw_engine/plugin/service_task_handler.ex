defmodule BfwEngine.Plugin.ServiceTaskHandler do
  @moduledoc """
  Handles Service Task execution for a specific **implementation** (dispatch key).

  Registered via `facade.register_service_task_handler.("my_type", MyHandler)`.
  Unique by `implementation` — duplicate registration is an error, not a crash.

  ## Return shapes

  * `{:async, ref}` — parks the FNI in `waiting`; complete later via
    `facade.service_tasks.finish_async.(flow_node_instance_id, result)`
    or fail via `facade.service_tasks.fail_async.(flow_node_instance_id, code, message)`.
    `ref` is typically `context.flow_node_instance_id`.
  * `{:error, reason}` — FNI transitions to `fatal`. Use for errors that
    occur before async work starts (validation, missing config, etc.).

  ## Async-only contract

  Service Task handlers are always asynchronous. `handle_enter/3` must
  return `{:async, ref}` and complete the FNI later through the facade
  completion API. Synchronous `{:ok, %FlowNodeResult{}}` returns are
  not supported.

  This is a deliberate design choice: Service Tasks represent external
  delegation to remote systems. The async contract enforces this
  boundary and prevents confusion with Script Tasks, which are the
  correct element for local, synchronous computation.

  `finish_async` / `fail_async` may be called before `handle_enter/3` has
  returned, also from `handle_enter/3` itself: the call is answered `:ok` at
  once and its result is applied when the flow node instance is parked in
  `waiting`. If the task ends any other way first, the result is dropped with
  a warning. A second such call for the same task is answered
  `{:error, :fni_not_waiting}`. The stored result is not persisted: after an
  engine restart the handler runs again with `resumed: true`.
  A call that meets an instance stopping for an engine shutdown is answered
  `{:error, :engine_shutting_down}`.

  If your work is conceptually synchronous (e.g. a fast API call), spawn
  a `Task` that performs the work and calls `finish_async` on completion:

      def handle_enter(_flow_node, token, context) do
        fni_id = context.flow_node_instance_id
        facade = MyPlugin.FacadeStore.get()

        Task.start(fn ->
          case MyApi.call(token.payload) do
            {:ok, result} ->
              facade.service_tasks.finish_async.(fni_id, result)
            {:error, reason} ->
              facade.service_tasks.fail_async.(fni_id, "API_ERROR", inspect(reason))
          end
        end)

        {:async, fni_id}
      end

  If your work is truly local computation with no external calls,
  consider using a Script Task with a Named Script plugin instead.
  See `BfwEngine.Plugin.NamedScript`.

  ## Engine restart

  Work started by `handle_enter/3` does not survive an engine restart. When
  a process instance resumes, each of its Service Task flow node instances
  that is still `waiting` stays `waiting`, and the engine publishes
  `PluginAsyncFlowNodeRehydrated`. If the handler implements the optional
  `handle_resume/2`, the engine then calls it in a separate process with the
  `t:resume_input/0` and the handler context. The handler decides: re-issue
  the work, or end the task with `finish_async` / `fail_async`. Its return
  value is ignored; a raise, exit, or throw fails the task with error code
  `handler_resume_raised`, which Error Boundaries can catch.

  A Service Task flow node instance that was still `active` (its start had
  not been parked) runs `handle_enter/3` again, with `resumed: true` in the
  handler context, so the handler can make its start idempotent.
  """

  @typedoc """
  What a resumed Service Task was parked with: its `implementation`, its
  flow node (`flow_node_id` and the parsed `flow_node`), and `mapped_input`,
  the input after `bfw:inputMapping` that `handle_enter/3` received as the
  token payload.
  """
  @type resume_input :: %{
          required(:implementation) => String.t(),
          required(:flow_node_id) => String.t(),
          required(:flow_node) => struct(),
          required(:mapped_input) => map()
        }

  @callback handle_enter(flow_node :: struct(), token :: struct(), handler_context :: struct()) ::
              {:async, String.t()} | {:error, term()}

  @callback handle_resume(resume_input(), handler_context :: struct()) :: term()

  @optional_callbacks handle_resume: 2
end
