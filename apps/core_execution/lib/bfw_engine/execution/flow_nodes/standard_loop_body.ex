defmodule BfwEngine.Execution.FlowNodes.StandardLoopBody do
  @moduledoc """
  Shell handler for `<bpmn:standardLoopCharacteristics>`.

  Implements both while-do (`test_before: true`) and do-while (`test_before: false`)
  loop semantics. Each iteration dispatches an iteration FNI via the PI's
  `{:mi_dispatch_iteration, ...}` call, reusing the same lightweight
  iteration infrastructure as Multi-Instance.

  The token chains through the iterations: iteration 0 receives the shell's
  input token, every later iteration receives the previous iteration's
  output, `loopCondition` is evaluated against the latest token, and the
  shell's output is the last iteration's output (the unchanged input token
  when no iteration ran).

  The shell FNI parks as `:waiting` while its continuation orchestrates
  iterations sequentially, evaluating `loop_condition` between passes.
  """

  @behaviour BfwEngine.Execution.FlowNodeHandler

  alias BfwEngine.BPMN.Model.FlowNode
  alias BfwEngine.BPMN.Model.StandardLoop
  alias BfwEngine.Events.EngineEventBus
  alias BfwEngine.Execution.DurationHelper
  alias BfwEngine.Execution.FlowNodeResult
  alias BfwEngine.Execution.FniLifecycle
  alias BfwEngine.Execution.HandlerContext
  alias BfwEngine.Execution.ProcessInstance.LaneResolution
  alias BfwEngine.Execution.SequenceFlowResolver
  alias BfwEngine.Expressions
  alias BfwEngine.Expressions.Context, as: FeelContext
  alias BfwEngine.Types.Event
  alias BfwEngine.Types.Token

  @impl true
  @spec handle_enter(FlowNode.t(), Token.t(), HandlerContext.t()) ::
          {:ok, FlowNodeResult.t()}
          | {:async, String.t(), (-> term()), map()}
          | {:error, term()}
  def handle_enter(flow_node, token, context) do
    emit_loop_started(context, flow_node)
    loop = new_loop(flow_node, token, context, [])

    if loop.standard_loop.test_before do
      case evaluate_condition(loop) do
        {:ok, true} -> park_loop_shell(loop)
        {:ok, false} -> finish_loop(loop, false)
        {:error, reason} -> {:error, reason}
      end
    else
      park_loop_shell(loop)
    end
  end

  defp park_loop_shell(loop) do
    continuation = fn ->
      if loop.standard_loop.test_before do
        loop_iterations(loop)
      else
        run_do_while(loop)
      end
    end

    case FniLifecycle.park_async(loop.context, %{mi_shell: true}) do
      :ok ->
        {:async, loop.context.flow_node_instance_id, continuation,
         %{persisted: true, mi_shell: true}}

      {:error, :persistence_failed} ->
        {:error, :persistence_failed}
    end
  end

  @doc """
  Standard Loop shell FNIs are not externally completable; iteration results
  flow through `{:mi_iteration_completed, ...}` messages, not `handle_complete`.
  """
  def handle_resume(flow_node, token, context) do
    case reattach_existing_iterations(context) do
      {:ok, snapshot} ->
        resume_from_snapshot(flow_node, token, context, snapshot)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reattach_existing_iterations(%HandlerContext{
         process_instance_pid: pid,
         flow_node_instance_id: id
       })
       when is_pid(pid) and is_binary(id) do
    :gen_statem.call(pid, {:mi_reattach_iterations, id}, :infinity)
  end

  defp reattach_existing_iterations(_context) do
    {:ok, %{live_count: 0, finished_payloads: [], occupied_indices: []}}
  end

  defp resume_from_snapshot(flow_node, token, context, snapshot) do
    if snapshot.live_count == 0 and snapshot.occupied_indices == [] do
      handle_enter(flow_node, token, context)
    else
      resume_attached_loop(flow_node, token, context, snapshot)
    end
  end

  defp resume_attached_loop(flow_node, token, context, snapshot) do
    finished =
      Enum.map(snapshot.finished_payloads, fn payload ->
        %FlowNodeResult{output_payload: payload}
      end)

    case collect_live_iteration_results(snapshot.live_count, []) do
      {:ok, live_results} ->
        flow_node
        |> new_loop(token, context, finished ++ Enum.reverse(live_results))
        |> loop_iterations()

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp collect_live_iteration_results(0, accumulated), do: {:ok, accumulated}

  defp collect_live_iteration_results(remaining, accumulated) do
    case wait_for_iteration_result() do
      {:ok, result} ->
        collect_live_iteration_results(remaining - 1, [result | accumulated])

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp new_loop(flow_node, token, context, collected) do
    %FlowNode{standard_loop: %StandardLoop{} = standard_loop} = flow_node

    %{
      flow_node: flow_node,
      token: token,
      context: context,
      standard_loop: standard_loop,
      collected: collected,
      current_payload: latest_payload(collected, token.payload || %{})
    }
  end

  defp latest_payload([], input_payload), do: input_payload

  defp latest_payload(collected, input_payload),
    do: List.last(collected).output_payload || input_payload

  # -- Do-while: first iteration runs unconditionally -------------------------

  defp run_do_while(loop) do
    with {:ok, loop} <- run_iteration(loop) do
      loop_iterations(loop)
    end
  end

  # -- Core loop iteration engine ---------------------------------------------

  defp loop_iterations(loop) do
    if reached_maximum?(loop) do
      finish_loop(loop, true)
    else
      continue_while_condition_holds(loop, evaluate_condition(loop))
    end
  end

  defp continue_while_condition_holds(loop, {:ok, true}) do
    maybe_wait_interval(loop.standard_loop, length(loop.collected))

    with {:ok, loop} <- run_iteration(loop) do
      loop_iterations(loop)
    end
  end

  defp continue_while_condition_holds(loop, {:ok, false}), do: finish_loop(loop, false)
  defp continue_while_condition_holds(_loop, {:error, reason}), do: {:error, reason}

  # -- Dispatch a single iteration and wait for result ------------------------

  defp run_iteration(loop) do
    index = length(loop.collected)

    loop_overlay = %{
      "item" => nil,
      "index" => index,
      "total" => nil,
      "completed" => index,
      "results" => Enum.map(loop.collected, fn result -> result.output_payload end)
    }

    iteration_token = %{loop.token | payload: loop.current_payload}

    case :gen_statem.call(
           loop.context.process_instance_pid,
           {:mi_dispatch_iteration, loop.context.flow_node_instance_id, index, nil,
            iteration_token, loop_overlay, loop.flow_node},
           :infinity
         ) do
      {:ok, _iteration_fni_id} ->
        record_iteration_result(loop, wait_for_iteration_result())

      {:error, reason} ->
        {:error, {:loop_dispatch_failed, reason}}
    end
  end

  defp record_iteration_result(loop, {:ok, result}) do
    {:ok,
     %{
       loop
       | collected: loop.collected ++ [result],
         current_payload: result.output_payload || loop.current_payload
     }}
  end

  defp record_iteration_result(_loop, {:error, reason}), do: {:error, reason}

  defp wait_for_iteration_result do
    receive do
      {:mi_iteration_completed, _fni_id, {:ok, result}} ->
        {:ok, result}

      {:mi_iteration_completed, _fni_id, {:error, reason}} ->
        {:error, reason}
    end
  end

  # -- Condition evaluation ---------------------------------------------------

  defp evaluate_condition(%{standard_loop: %StandardLoop{loop_condition: nil}}), do: {:ok, true}

  defp evaluate_condition(loop) do
    completed_count = length(loop.collected)
    result_payloads = Enum.map(loop.collected, fn result -> result.output_payload end)

    feel_context =
      loop.context
      |> FeelContext.from_handler_context(loop.current_payload)
      |> FeelContext.put_loop_bindings(
        max(completed_count - 1, 0),
        nil,
        completed_count,
        result_payloads,
        nil
      )

    case Expressions.eval(loop.standard_loop.loop_condition, feel_context) do
      {:ok, value} ->
        {:ok, value == true}

      {:error, reason} ->
        {:error,
         {:loop_condition_failed,
          %{
            flow_node_id: loop.flow_node.id,
            condition: "loopCondition",
            expression: loop.standard_loop.loop_condition,
            reason: to_string(reason)
          }}}
    end
  end

  # -- Maximum check ----------------------------------------------------------

  defp reached_maximum?(%{standard_loop: %StandardLoop{loop_maximum: nil}}), do: false

  defp reached_maximum?(%{standard_loop: %StandardLoop{loop_maximum: max}, collected: collected}) do
    length(collected) >= max
  end

  # -- Interval ---------------------------------------------------------------

  defp maybe_wait_interval(_standard_loop, 0), do: :ok
  defp maybe_wait_interval(%StandardLoop{loop_interval: nil}, _index), do: :ok

  defp maybe_wait_interval(%StandardLoop{loop_interval: interval}, _index) do
    case DurationHelper.parse_duration_to_ms(interval) do
      {:ok, ms} when ms > 0 -> Process.sleep(ms)
      _ -> :ok
    end
  end

  # -- Finish -----------------------------------------------------------------

  defp finish_loop(loop, early_break) do
    completed = length(loop.collected)
    output = loop.current_payload

    emit_loop_completed(loop.context, loop.flow_node, completed, early_break)

    type_properties = %{
      "standard_loop" => %{
        "test_before" => loop.standard_loop.test_before,
        "total_iterations" => completed,
        "loop_maximum" => loop.standard_loop.loop_maximum
      }
    }

    with {:ok, next_ids} <- resolve_outgoing(loop.flow_node, loop.context),
         {:ok, _lifecycle} <-
           FniLifecycle.finish(loop.context, loop.flow_node, output, type_properties) do
      {:ok,
       %FlowNodeResult{
         output_payload: output,
         type_properties: type_properties,
         next_flow_node_ids: next_ids
       }}
    end
  end

  # -- Event emission -----------------------------------------------------------

  defp emit_loop_started(context, flow_node) do
    EngineEventBus.publish(%Event.MultiInstanceStarted{
      flow_node_instance_id: context.flow_node_instance_id,
      process_instance_id: context.process_instance_id,
      root_process_instance_id: context.root_process_instance_id,
      flow_node_id: flow_node.id,
      flow_node_type: flow_node.type,
      loop_type: "standard_loop",
      total_iterations: nil,
      lane_name: LaneResolution.resolve_lane_name_from_context(context, flow_node),
      occurred_at: DateTime.utc_now()
    })
  end

  defp emit_loop_completed(context, flow_node, completed, early_break) do
    EngineEventBus.publish(%Event.MultiInstanceCompleted{
      flow_node_instance_id: context.flow_node_instance_id,
      process_instance_id: context.process_instance_id,
      root_process_instance_id: context.root_process_instance_id,
      flow_node_id: flow_node.id,
      flow_node_type: flow_node.type,
      loop_type: "standard_loop",
      total_iterations: nil,
      completed_iterations: completed,
      early_break: early_break,
      lane_name: LaneResolution.resolve_lane_name_from_context(context, flow_node),
      occurred_at: DateTime.utc_now()
    })
  end

  # -- Outgoing sequence flow resolution ----------------------------------------

  defp resolve_outgoing(flow_node, context) do
    case SequenceFlowResolver.resolve(flow_node, context.process_model) do
      {:ok, targets} -> {:ok, Enum.map(targets, & &1.id)}
      {:error, reason, meta} -> {:error, Map.put(meta, :reason, reason)}
    end
  end
end
