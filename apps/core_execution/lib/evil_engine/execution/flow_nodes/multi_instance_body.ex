defmodule EvilEngine.Execution.FlowNodes.MultiInstanceBody do
  @moduledoc """
  MI shell handler for `<bpmn:multiInstanceLoopCharacteristics>`.

  Manages the full lifecycle of a multi-instance activity: evaluates the
  input collection, dispatches iteration FNIs (parallel or sequential),
  collects results, evaluates `completionCondition` / `loopBreakCondition`,
  and produces the aggregated output.

  The shell FNI parks as `:waiting` while its continuation-fn orchestrates
  iterations via `{:mi_dispatch_iteration, ...}` calls to the PI.
  """

  @behaviour EvilEngine.Execution.FlowNodeHandler

  alias EvilEngine.BPMN.Model.FlowNode
  alias EvilEngine.BPMN.Model.MultiInstance
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
          | {:error, term()}
  def handle_enter(flow_node, token, context) do
    %FlowNode{multi_instance: %MultiInstance{} = mi} = flow_node

    feel_context = FeelContext.from_handler_context(context, token.payload || %{})

    with {:ok, collection} <- evaluate_collection(mi, feel_context),
         {:ok, collection} <- validate_collection(collection) do
      dispatch_mi_strategy(flow_node, token, context, mi, collection)
    end
  end

  defp dispatch_mi_strategy(flow_node, _token, context, mi, []) do
    emit_mi_started(context, flow_node, mi, 0)
    emit_mi_completed(context, flow_node, mi, 0, 0, false)
    output = %{"results" => []}
    type_properties = mi_type_properties(mi, 0, [])

    with {:ok, next_ids} <- resolve_outgoing(flow_node, context),
         {:ok, _lifecycle} <- FniLifecycle.finish(context, flow_node, output, type_properties) do
      {:ok, %FlowNodeResult{
        output_payload: output,
        type_properties: type_properties,
        next_flow_node_ids: next_ids
      }}
    end
  end

  defp dispatch_mi_strategy(flow_node, token, context, %MultiInstance{is_sequential: true} = mi, collection) do
    emit_mi_started(context, flow_node, mi, length(collection))
    run_sequential(flow_node, token, context, mi, collection)
  end

  defp dispatch_mi_strategy(flow_node, token, context, mi, collection) do
    emit_mi_started(context, flow_node, mi, length(collection))
    run_parallel(flow_node, token, context, mi, collection)
  end

  @doc """
  MI shell FNIs are not externally completable; iteration results flow
  through `{:mi_iteration_completed, ...}` messages, not `handle_complete`.
  """
  def handle_resume(flow_node, token, context) do
    handle_enter(flow_node, token, context)
  end

  # -- Collection evaluation ---------------------------------------------------

  defp evaluate_collection(%MultiInstance{collection_expression: nil}, _feel_context) do
    {:error, :missing_collection_expression}
  end

  defp evaluate_collection(mi, feel_context) do
    case Expressions.eval(mi.collection_expression, feel_context) do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, {:collection_eval_failed, reason}}
    end
  end

  defp validate_collection(collection) when is_list(collection), do: {:ok, collection}
  defp validate_collection(_other), do: {:error, :collection_not_a_list}

  # -- Parallel MI strategy ---------------------------------------------------

  defp run_parallel(flow_node, token, context, mi, collection) do
    with :ok <- validate_parallel_max_iterations(collection, mi) do
      dispatch_all_parallel(flow_node, token, context, mi, collection)
    end
  end

  defp dispatch_all_parallel(flow_node, token, context, mi, collection) do
    total = length(collection)
    token_payload = token.payload || %{}
    process_instance_pid = context.process_instance_pid
    flow_node_instance_id = context.flow_node_instance_id

    dispatched =
      collection
      |> Enum.with_index()
      |> Enum.map(fn {item, index} ->
        iteration_token = build_iteration_token(token, mi, item, index, total)
        loop_overlay = build_loop_overlay(item, index, total, [])

        case :gen_statem.call(
               process_instance_pid,
               {:mi_dispatch_iteration, flow_node_instance_id, index, item,
                iteration_token, loop_overlay, flow_node}
             ) do
          {:ok, iteration_fni_id} -> {:ok, iteration_fni_id, index}
          {:error, reason} -> {:error, reason, index}
        end
      end)

    errors = Enum.filter(dispatched, &match?({:error, _, _}, &1))

    if errors != [] do
      {:error, {:mi_dispatch_failed, errors}}
    else
      collect_parallel_results(
        flow_node, mi, total, total, context, token_payload
      )
    end
  end

  defp validate_parallel_max_iterations(_collection, %MultiInstance{max_iterations: nil}), do: :ok

  defp validate_parallel_max_iterations(collection, %MultiInstance{max_iterations: max}) do
    size = length(collection)

    if size > max do
      {:error,
       {:collection_exceeds_max_iterations, %{collection_size: size, max_iterations: max}}}
    else
      :ok
    end
  end

  defp cap_at_max_iterations(collection, %MultiInstance{max_iterations: nil}), do: collection

  defp cap_at_max_iterations(collection, %MultiInstance{max_iterations: max}) do
    Enum.take(collection, max)
  end

  defp collect_parallel_results(flow_node, mi, total, dispatched_count, context, token_payload) do
    results = collect_iteration_results(dispatched_count, mi, total, context, token_payload, [])

    case results do
      {:ok, collected} ->
        early_break = length(collected) < total
        emit_mi_completed(context, flow_node, mi, total, length(collected), early_break)
        output = build_output_collection(mi, collected, total, context, token_payload)
        type_properties = mi_type_properties(mi, total, collected)

        with {:ok, next_ids} <- resolve_outgoing(flow_node, context),
             {:ok, _lifecycle} <- FniLifecycle.finish(context, flow_node, output, type_properties) do
          {:ok, %FlowNodeResult{
            output_payload: output,
            type_properties: type_properties,
            next_flow_node_ids: next_ids
          }}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # -- Sequential MI strategy -------------------------------------------------

  defp run_sequential(flow_node, token, context, mi, collection) do
    effective_collection = cap_at_max_iterations(collection, mi)
    total = length(collection)
    token_payload = token.payload || %{}

    result =
      effective_collection
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, []}, fn {item, index}, {:ok, rev_accumulated} ->
        execute_sequential_iteration(
          flow_node, token, context, mi, item, index, total, rev_accumulated
        )
      end)

    case result do
      {:ok, rev_collected} ->
        collected = Enum.reverse(rev_collected)
        early_break = length(collected) < total
        emit_mi_completed(context, flow_node, mi, total, length(collected), early_break)
        output = build_output_collection(mi, collected, total, context, token_payload)
        type_properties = mi_type_properties(mi, total, collected)

        with {:ok, next_ids} <- resolve_outgoing(flow_node, context),
             {:ok, _lifecycle} <- FniLifecycle.finish(context, flow_node, output, type_properties) do
          {:ok, %FlowNodeResult{
            output_payload: output,
            type_properties: type_properties,
            next_flow_node_ids: next_ids
          }}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp execute_sequential_iteration(flow_node, token, context, mi, item, index, total, rev_accumulated) do
    maybe_wait_interval(mi, index)

    accumulated = Enum.reverse(rev_accumulated)
    iteration_token = build_iteration_token(token, mi, item, index, total)
    loop_overlay = build_loop_overlay(item, index, total, accumulated)

    case dispatch_and_await_iteration(context, flow_node, index, item, iteration_token, loop_overlay) do
      {:ok, iteration_result} ->
        collected = [iteration_result | rev_accumulated]
        token_payload = token.payload || %{}

        if should_break?(mi, Enum.reverse(collected), total, context, token_payload) do
          {:halt, {:ok, collected}}
        else
          {:cont, {:ok, collected}}
        end

      {:error, reason} ->
        {:halt, {:error, reason}}
    end
  end

  defp dispatch_and_await_iteration(context, flow_node, index, item, iteration_token, loop_overlay) do
    case :gen_statem.call(
           context.process_instance_pid,
           {:mi_dispatch_iteration, context.flow_node_instance_id, index, item,
            iteration_token, loop_overlay, flow_node},
           @iteration_timeout_ms
         ) do
      {:ok, _iteration_fni_id} ->
        wait_for_iteration_result()

      {:error, reason} ->
        {:error, {:mi_dispatch_failed, reason}}
    end
  end

  # -- Result collection ------------------------------------------------------

  defp collect_iteration_results(0, _mi, _total, _context, _token_payload, accumulated) do
    {:ok, Enum.reverse(accumulated)}
  end

  defp collect_iteration_results(remaining, mi, total, context, token_payload, accumulated) do
    case wait_for_iteration_result() do
      {:ok, result} ->
        collected = [result | accumulated]

        if should_break?(mi, Enum.reverse(collected), total, context, token_payload) do
          drain_remaining_results(remaining - 1)
          {:ok, Enum.reverse(collected)}
        else
          collect_iteration_results(remaining - 1, mi, total, context, token_payload, collected)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp drain_remaining_results(0), do: :ok

  defp drain_remaining_results(remaining) do
    receive do
      {:mi_iteration_completed, _fni_id, _result} ->
        drain_remaining_results(remaining - 1)
    after
      @iteration_timeout_ms -> :ok
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

  # -- Break condition evaluation ---------------------------------------------

  defp should_break?(mi, collected, total, context, token_payload) do
    check_max_iterations(mi, collected) ||
      check_completion_condition(mi, collected, total, context, token_payload) ||
      check_loop_break_condition(mi, collected, total, context, token_payload)
  end

  defp check_max_iterations(%MultiInstance{max_iterations: nil}, _collected), do: false

  defp check_max_iterations(%MultiInstance{max_iterations: max}, collected) do
    length(collected) >= max
  end

  defp check_completion_condition(%MultiInstance{completion_condition: nil}, _, _, _, _), do: false

  defp check_completion_condition(mi, collected, total, context, token_payload) do
    evaluate_break_expression(
      mi.completion_condition,
      collected, total, context, token_payload
    )
  end

  defp check_loop_break_condition(%MultiInstance{loop_break_condition: nil}, _, _, _, _), do: false

  defp check_loop_break_condition(mi, collected, total, context, token_payload) do
    evaluate_break_expression(
      mi.loop_break_condition,
      collected, total, context, token_payload
    )
  end

  defp evaluate_break_expression(expression, collected, total, context, token_payload) do
    feel_context = FeelContext.from_handler_context(context, token_payload)
    completed_count = length(collected)
    result_payloads = Enum.map(collected, fn r -> r.output_payload end)

    feel_context =
      FeelContext.put_loop_bindings(
        feel_context,
        max(completed_count - 1, 0),
        total,
        completed_count,
        result_payloads,
        nil
      )

    case Expressions.eval(expression, feel_context) do
      {:ok, true} -> true
      _ -> false
    end
  end

  # -- Token and overlay construction -----------------------------------------

  defp build_iteration_token(token, mi, item, _index, _total) do
    element_variable = mi.element_variable || "item"
    payload = Map.put(token.payload || %{}, element_variable, item)
    %{token | payload: payload}
  end

  defp build_loop_overlay(item, index, total, completed_results) do
    %{
      "item" => item,
      "index" => index,
      "total" => total,
      "completed" => length(completed_results),
      "results" => Enum.map(completed_results, fn r -> r.output_payload end)
    }
  end

  # -- Output collection building ---------------------------------------------

  defp build_output_collection(mi, collected, total, context, token_payload) do
    results = Enum.map(collected, fn r -> r.output_payload end)

    if mi.output_collection do
      feel_context = FeelContext.from_handler_context(context, token_payload)
      completed_count = length(collected)

      feel_context =
        FeelContext.put_loop_bindings(
          feel_context,
          max(completed_count - 1, 0),
          total,
          completed_count,
          results,
          nil
        )

      case Expressions.eval(mi.output_collection, feel_context) do
        {:ok, value} -> value
        _ -> %{"results" => results}
      end
    else
      %{"results" => results}
    end
  end

  # -- Type properties --------------------------------------------------------

  defp mi_type_properties(mi, total, collected) do
    %{
      "multi_instance" => %{
        "is_sequential" => mi.is_sequential,
        "total_iterations" => total,
        "completed_iterations" => length(collected),
        "early_break" => length(collected) < total
      }
    }
  end

  # -- Interval for sequential MI ---------------------------------------------

  defp maybe_wait_interval(_mi, 0), do: :ok

  defp maybe_wait_interval(%MultiInstance{loop_interval: nil}, _index), do: :ok

  defp maybe_wait_interval(%MultiInstance{loop_interval: interval}, _index) do
    case DurationHelper.parse_duration_to_ms(interval) do
      {:ok, ms} when ms > 0 -> Process.sleep(ms)
      _ -> :ok
    end
  end

  # -- Event emission -----------------------------------------------------------

  defp loop_type(%MultiInstance{is_sequential: true}), do: "sequential_mi"
  defp loop_type(%MultiInstance{is_sequential: false}), do: "parallel_mi"

  defp emit_mi_started(context, flow_node, mi, total) do
    EngineEventBus.publish(%Event.MultiInstanceStarted{
      flow_node_instance_id: context.flow_node_instance_id,
      process_instance_id: context.process_instance_id,
      root_process_instance_id: context.root_process_instance_id,
      flow_node_id: flow_node.id,
      flow_node_type: flow_node.type,
      loop_type: loop_type(mi),
      total_iterations: total,
      lane_name: Helpers.resolve_lane_name_from_context(context, flow_node),
      occurred_at: DateTime.utc_now()
    })
  end

  defp emit_mi_completed(context, flow_node, mi, total, completed, early_break) do
    EngineEventBus.publish(%Event.MultiInstanceCompleted{
      flow_node_instance_id: context.flow_node_instance_id,
      process_instance_id: context.process_instance_id,
      root_process_instance_id: context.root_process_instance_id,
      flow_node_id: flow_node.id,
      flow_node_type: flow_node.type,
      loop_type: loop_type(mi),
      total_iterations: total,
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
