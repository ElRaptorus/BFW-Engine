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

  `finish_async` / `fail_async` may be called from another process before
  `handle_enter/3` has returned: the engine holds the call until the flow
  node instance is parked in `waiting`, then answers it. A call made by
  `handle_enter/3` itself, in its own process, is answered
  `{:error, :fni_not_waiting}`.

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
  value is ignored; a raise is logged and leaves the task `waiting`.
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
