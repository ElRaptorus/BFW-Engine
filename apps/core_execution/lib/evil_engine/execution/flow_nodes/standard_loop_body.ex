defmodule EvilEngine.Execution.FlowNodes.StandardLoopBody do
  @moduledoc """
  Shell handler for `<bpmn:standardLoopCharacteristics>`.

  Implements both while-do (`test_before: true`) and do-while (`test_before: false`)
  loop semantics. Each iteration dispatches an iteration FNI via the PI's
  `{:mi_dispatch_iteration, ...}` call, reusing the same lightweight
  iteration infrastructure as Multi-Instance.

  The shell FNI parks as `:waiting` while its continuation orchestrates
  iterations sequentially, evaluating `loop_condition` between passes.
  """

  @behaviour EvilEngine.Execution.FlowNodeHandler

  alias EvilEngine.BPMN.Model.FlowNode
  alias EvilEngine.BPMN.Model.StandardLoop
  alias EvilEngine.Events.EngineEventBus
  alias EvilEngine.Execution.DurationHelper
  alias EvilEngine.Execution.FlowNodeResult
  alias EvilEngine.Execution.FniLifecycle
  alias EvilEngine.Execution.HandlerContext
  alias EvilEngine.Execution.ProcessInstance.Helpers
  alias EvilEngine.Execution.SequenceFlowResolver
  alias EvilEngine.Expressions
  alias EvilEngine.Expressions.Context, as: FeelContext
  alias EvilEngine.Types.Event
  alias EvilEngine.Types.Token

  @iteration_timeout_ms 300_000

  @impl true
  @spec handle_enter(FlowNode.t(), Token.t(), HandlerContext.t()) ::
          {:ok, FlowNodeResult.t()}
          | {:async, String.t(), (-> term()), map()}
          | {:error, term()}
  def handle_enter(flow_node, token, context) do
    %FlowNode{standard_loop: %StandardLoop{} = sl} = flow_node

    emit_loop_started(context, flow_node)
    park_or_run_loop(flow_node, token, context, sl)
  end

  defp park_or_run_loop(flow_node, token, context, sl) do
    token_payload = token.payload || %{}

    if sl.test_before and not evaluate_condition(sl, [], context, token_payload) do
      run_while_do(flow_node, token, context, sl)
    else
      park_loop_shell(flow_node, token, context, sl)
    end
  end

  defp park_loop_shell(flow_node, token, context, sl) do
    continuation = fn ->
      if sl.test_before do
        run_while_do(flow_node, token, context, sl)
      else
        run_do_while(flow_node, token, context, sl)
      end
    end

    case FniLifecycle.park_async(context, %{mi_shell: true}) do
      :ok ->
        {:async, context.flow_node_instance_id, continuation, %{persisted: true, mi_shell: true}}

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
    :gen_statem.call(pid, {:mi_reattach_iterations, id})
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
    %FlowNode{standard_loop: %StandardLoop{} = standard_loop} = flow_node
    token_payload = token.payload || %{}

    finished =
      Enum.map(snapshot.finished_payloads, fn payload ->
        %FlowNodeResult{output_payload: payload}
      end)

    case collect_live_iteration_results(snapshot.live_count, []) do
      {:ok, live_results} ->
        collected = finished ++ Enum.reverse(live_results)

        loop_iterations(
          flow_node,
          token,
          context,
          standard_loop,
          length(collected),
          collected,
          token_payload
        )

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

  # -- While-do: condition checked before each iteration ----------------------

  defp run_while_do(flow_node, token, context, sl) do
    token_payload = token.payload || %{}
    loop_iterations(flow_node, token, context, sl, 0, [], token_payload)
  end

  # -- Do-while: first iteration runs unconditionally -------------------------

  defp run_do_while(flow_node, token, context, sl) do
    token_payload = token.payload || %{}

    case dispatch_and_wait(flow_node, token, context, 0, []) do
      {:ok, result, _iteration_token} ->
        collected = [result]

        cond do
          reached_maximum?(sl, collected) ->
            finish_loop(context, flow_node, sl, collected, true)

          condition_false?(sl, collected, context, token_payload) ->
            finish_loop(context, flow_node, sl, collected, false)

          true ->
            loop_iterations(flow_node, token, context, sl, 1, collected, token_payload)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # -- Core loop iteration engine ---------------------------------------------

  defp loop_iterations(flow_node, token, context, sl, index, collected, token_payload) do
    cond do
      reached_maximum?(sl, collected) ->
        finish_loop(context, flow_node, sl, collected, true)

      not evaluate_condition(sl, collected, context, token_payload) ->
        finish_loop(context, flow_node, sl, collected, false)

      true ->
        maybe_wait_interval(sl, index)
        execute_next_iteration(flow_node, token, context, sl, index, collected, token_payload)
    end
  end

  defp execute_next_iteration(flow_node, token, context, sl, index, collected, token_payload) do
    case dispatch_and_wait(flow_node, token, context, index, collected) do
      {:ok, result, _iteration_token} ->
        loop_iterations(
          flow_node,
          token,
          context,
          sl,
          index + 1,
          collected ++ [result],
          token_payload
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  # -- Dispatch a single iteration and wait for result ------------------------

  defp dispatch_and_wait(flow_node, token, context, index, collected) do
    process_instance_pid = context.process_instance_pid
    flow_node_instance_id = context.flow_node_instance_id

    results = Enum.map(collected, fn r -> r.output_payload end)

    loop_overlay = %{
      "item" => nil,
      "index" => index,
      "total" => nil,
      "completed" => length(collected),
      "results" => results
    }

    iteration_token = token

    case :gen_statem.call(
           process_instance_pid,
           {:mi_dispatch_iteration, flow_node_instance_id, index, nil, iteration_token,
            loop_overlay, flow_node}
         ) do
      {:ok, _iteration_fni_id} ->
        case wait_for_iteration_result() do
          {:ok, result} -> {:ok, result, iteration_token}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, {:loop_dispatch_failed, reason}}
    end
  end

  defp wait_for_iteration_result do
    receive do
      {:mi_iteration_completed, _fni_id, {:ok, result}} ->
        {:ok, result}

      {:mi_iteration_completed, _fni_id, {:error, reason}} ->
        {:error, reason}
    after
      @iteration_timeout_ms ->
        {:error, :iteration_timeout}
    end
  end

  # -- Condition evaluation ---------------------------------------------------

  defp evaluate_condition(
         %StandardLoop{loop_condition: nil},
         _collected,
         _context,
         _token_payload
       ) do
    true
  end

  defp evaluate_condition(sl, collected, context, token_payload) do
    feel_context = FeelContext.from_handler_context(context, token_payload)
    completed_count = length(collected)
    result_payloads = Enum.map(collected, fn r -> r.output_payload end)

    feel_context =
      FeelContext.put_loop_bindings(
        feel_context,
        max(completed_count - 1, 0),
        nil,
        completed_count,
        result_payloads,
        nil
      )

    case Expressions.eval(sl.loop_condition, feel_context) do
      {:ok, true} -> true
      _ -> false
    end
  end

  defp condition_false?(sl, collected, context, token_payload) do
    not evaluate_condition(sl, collected, context, token_payload)
  end

  # -- Maximum check ----------------------------------------------------------

  defp reached_maximum?(%StandardLoop{loop_maximum: nil}, _collected), do: false

  defp reached_maximum?(%StandardLoop{loop_maximum: max}, collected) do
    length(collected) >= max
  end

  # -- Interval ---------------------------------------------------------------

  defp maybe_wait_interval(_sl, 0), do: :ok
  defp maybe_wait_interval(%StandardLoop{loop_interval: nil}, _index), do: :ok

  defp maybe_wait_interval(%StandardLoop{loop_interval: interval}, _index) do
    case DurationHelper.parse_duration_to_ms(interval) do
      {:ok, ms} when ms > 0 -> Process.sleep(ms)
      _ -> :ok
    end
  end

  # -- Finish -----------------------------------------------------------------

  defp finish_loop(context, flow_node, sl, collected, early_break) do
    results = Enum.map(collected, fn r -> r.output_payload end)
    output = %{"results" => results}
    completed = length(collected)

    emit_loop_completed(context, flow_node, completed, early_break)

    type_properties = %{
      "standard_loop" => %{
        "test_before" => sl.test_before,
        "total_iterations" => completed,
        "loop_maximum" => sl.loop_maximum
      }
    }

    with {:ok, next_ids} <- resolve_outgoing(flow_node, context),
         {:ok, _lifecycle} <- FniLifecycle.finish(context, flow_node, output, type_properties) do
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
      lane_name: Helpers.resolve_lane_name_from_context(context, flow_node),
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
      lane_name: Helpers.resolve_lane_name_from_context(context, flow_node),
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
