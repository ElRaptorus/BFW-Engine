defmodule EvilEngine.Execution.ProcessInstance.CompensationOrchestrator do
  @moduledoc """
  Compensation run planner and runtime dispatcher.

  Builds the LIFO handler queue (`build_run/4`) and, when invoked from the
  Process Instance `:gen_statem`, persists and spawns compensation handler
  FNIs. The PI keeps thin wrappers that pass a `runtime` callback map for
  helpers that remain private on the Process Instance (event emission and
  successor FNI dispatch).
  """

  require Logger

  import EvilEngine.Execution.ProcessInstance.Helpers

  alias EvilEngine.Events.EngineEventBus
  alias EvilEngine.Execution.BoundaryAwareHandler
  alias EvilEngine.Execution.HandlerDispatch
  alias EvilEngine.Execution.Persistence, as: PersistenceAdapter
  alias EvilEngine.Execution.PersistenceRetry
  alias EvilEngine.Types.Event
  alias EvilEngine.Types.Token

  @type compensation_target :: %{
          completed_fni_id: String.t(),
          flow_node_id: String.t(),
          handler_activity_id: String.t(),
          token_snapshot: map(),
          completion_order: non_neg_integer()
        }

  @type compensation_run :: %{
          queue: [compensation_target()],
          cursor: non_neg_integer(),
          mode: :broadcast | :single | :esp,
          throw_type: :throw | :end | :cancel,
          outgoing_flow_node_ids: [String.t()],
          token_payload: map()
        }

  @type runtime :: %{
          emit_fni_started: (map(), String.t(), struct(), [String.t()] -> :ok),
          emit_fni_state_changed: (map(), String.t(), map(), atom(), atom() -> :ok),
          emit_compensation_triggered: (map(), String.t(), map(), non_neg_integer() -> :ok),
          dispatch_flow_node_instance: (map(), struct(), Token.t(), [String.t()] -> map())
        }

  @doc """
  Build a compensation run from resolved targets.

  Returns a `compensation_run` map ready to be stored in
  `data.compensation_runs[throw_fni_id]`.
  """
  @spec build_run(
          [compensation_target()],
          :throw | :end | :cancel,
          [String.t()],
          map()
        ) :: compensation_run()
  def build_run(targets, throw_type, outgoing_flow_node_ids, token_payload) do
    mode =
      case targets do
        [_single] -> :single
        _ -> :broadcast
      end

    %{
      queue: targets,
      cursor: 0,
      mode: mode,
      throw_type: throw_type,
      outgoing_flow_node_ids: outgoing_flow_node_ids,
      token_payload: token_payload
    }
  end

  @doc """
  Return the current target from the run, or `nil` if the run is complete.
  """
  @spec current_target(compensation_run()) :: compensation_target() | nil
  def current_target(%{queue: queue, cursor: cursor}) do
    Enum.at(queue, cursor)
  end

  @doc """
  Advance the cursor by one position. Returns the updated run.
  """
  @spec advance_cursor(compensation_run()) :: compensation_run()
  def advance_cursor(run) do
    %{run | cursor: run.cursor + 1}
  end

  @doc """
  Check whether the run has completed all targets.
  """
  @spec run_complete?(compensation_run()) :: boolean()
  def run_complete?(%{queue: queue, cursor: cursor}) do
    cursor >= length(queue)
  end

  @doc """
  Start a cancel-end compensation run (broadcast, LIFO registry order).
  """
  @spec start_cancel_run(map(), String.t(), runtime()) :: map()
  def start_cancel_run(data, cancel_fni_id, runtime) do
    targets =
      data.compensation_registry
      |> Enum.sort_by(& &1.completion_order, :desc)

    if targets == [] do
      %{data | cancel_reached: true}
    else
      cancel_entry = Map.get(data.flow_node_instance_states, cancel_fni_id)
      output_payload = if cancel_entry, do: cancel_entry.token.payload, else: %{}

      run = build_run(targets, :cancel, [], output_payload)
      data = put_in(data.compensation_runs[cancel_fni_id], run)
      dispatch_next_handler(data, cancel_fni_id, runtime)
    end
  end

  @doc """
  Park the throw FNI as waiting and dispatch the first compensation handler.
  """
  @spec start_run(map(), String.t(), map(), map(), map(), [compensation_target()], runtime()) ::
          map()
  def start_run(data, flow_node_instance_id, result, run_spec, entry, targets, runtime) do
    output_payload = result.output_payload || entry.token.payload

    run =
      build_run(
        targets,
        run_spec.throw_type,
        run_spec.outgoing_flow_node_ids,
        output_payload
      )

    type_properties = %{
      compensation_run: true,
      throw_type: Atom.to_string(run_spec.throw_type),
      target_count: length(targets),
      cursor: 0
    }

    data =
      put_in(data.flow_node_instance_states[flow_node_instance_id], %{
        entry
        | state: :waiting,
          pid: nil,
          token: %{entry.token | payload: output_payload},
          type_properties: type_properties
      })

    data = put_in(data.compensation_runs[flow_node_instance_id], run)

    _persist = persist_throw_waiting(data, flow_node_instance_id, type_properties, runtime)

    runtime.emit_compensation_triggered.(
      data,
      flow_node_instance_id,
      run_spec,
      length(targets)
    )

    dispatch_next_handler(data, flow_node_instance_id, runtime)
  end

  @doc """
  Advance the run cursor after a handler FNI finishes and dispatch the next.
  """
  @spec advance_run(map(), String.t(), runtime()) :: map()
  def advance_run(data, throw_fni_id, runtime) do
    case Map.get(data.compensation_runs, throw_fni_id) do
      nil ->
        data

      run ->
        run = advance_cursor(run)
        throw_entry = Map.get(data.flow_node_instance_states, throw_fni_id)

        if throw_entry do
          cursor_properties = Map.merge(throw_entry.type_properties, %{cursor: run.cursor})

          data =
            put_in(
              data.flow_node_instance_states[throw_fni_id],
              %{throw_entry | type_properties: cursor_properties}
            )

          data = put_in(data.compensation_runs[throw_fni_id], run)
          dispatch_next_handler(data, throw_fni_id, runtime)
        else
          data
        end
    end
  end

  @doc false
  @spec dispatch_next_handler(map(), String.t(), runtime()) :: map()
  def dispatch_next_handler(data, throw_fni_id, runtime) do
    run = Map.fetch!(data.compensation_runs, throw_fni_id)
    target = current_target(run)

    if target == nil do
      finish_run(data, throw_fni_id, run, runtime)
    else
      handler_node = find_flow_node(data, target.handler_activity_id)

      if handler_node == nil do
        Logger.warning(
          "Compensation handler activity #{target.handler_activity_id} not found in model, " <>
            "skipping for throw FNI #{throw_fni_id}"
        )

        data = put_in(data.compensation_runs[throw_fni_id], advance_cursor(run))
        dispatch_next_handler(data, throw_fni_id, runtime)
      else
        handler_token = %Token{
          id: generate_id(),
          process_instance_id: data.process_instance_id,
          payload: target.token_snapshot,
          originating_flow_node_instance_id: throw_fni_id,
          created_at: DateTime.utc_now()
        }

        handler_type_properties = %{
          compensation_for: target.completed_fni_id,
          compensation_throw_fni_id: throw_fni_id
        }

        dispatch_handler_fni(
          data,
          handler_node,
          handler_token,
          throw_fni_id,
          handler_type_properties,
          runtime
        )
      end
    end
  end

  @doc """
  Complete a compensation run: persist the throw FNI as finished and
  dispatch its outgoing sequence flows (`:throw`), set
  `compensation_end_reached` (`:end`), or set `cancel_reached` (`:cancel`).
  """
  @spec finish_run(map(), String.t(), compensation_run(), runtime()) :: map()
  def finish_run(data, throw_fni_id, run, runtime) do
    data = %{data | compensation_runs: Map.delete(data.compensation_runs, throw_fni_id)}

    case run.throw_type do
      :throw ->
        entry = Map.fetch!(data.flow_node_instance_states, throw_fni_id)

        node_index = Map.new(data.process_model.flow_nodes, &{&1.id, &1})

        targets =
          run.outgoing_flow_node_ids
          |> Enum.map(&Map.get(node_index, &1))
          |> Enum.reject(&is_nil/1)

        new_token = %Token{
          id: generate_id(),
          process_instance_id: data.process_instance_id,
          payload: run.token_payload,
          originating_flow_node_instance_id: throw_fni_id,
          created_at: DateTime.utc_now()
        }

        data =
          put_in(data.flow_node_instance_states[throw_fni_id], %{
            entry
            | state: :finished
          })

        _persist = persist_throw_finished(data, throw_fni_id, runtime)

        Enum.reduce(targets, data, fn target_node, accumulator ->
          runtime.dispatch_flow_node_instance.(accumulator, target_node, new_token, [throw_fni_id])
        end)

      :end ->
        entry = Map.fetch!(data.flow_node_instance_states, throw_fni_id)

        data =
          put_in(data.flow_node_instance_states[throw_fni_id], %{
            entry
            | state: :finished
          })

        _persist = persist_throw_finished(data, throw_fni_id, runtime)
        %{data | compensation_end_reached: true}

      :cancel ->
        %{data | cancel_reached: true}
    end
  end

  defp dispatch_handler_fni(
         data,
         handler_node,
         token,
         throw_fni_id,
         extra_type_properties,
         runtime
       ) do
    flow_node_instance_id = generate_id()
    lane_name = resolve_lane_name(data.process_model, handler_node)

    case persist_handler_fni(
           data,
           flow_node_instance_id,
           handler_node,
           token,
           lane_name,
           throw_fni_id,
           extra_type_properties
         ) do
      {:ok, _} ->
        runtime.emit_fni_started.(data, flow_node_instance_id, handler_node, [throw_fni_id])

        spawn_handler_task(
          data,
          flow_node_instance_id,
          handler_node,
          token,
          throw_fni_id,
          extra_type_properties
        )

      {:error, reason} ->
        Logger.error(
          "Compensation: failed to persist handler FNI #{flow_node_instance_id}: #{inspect(reason)}"
        )

        data
    end
  end

  defp persist_handler_fni(
         data,
         flow_node_instance_id,
         handler_node,
         token,
         lane_name,
         throw_fni_id,
         extra_type_properties
       ) do
    adapter = PersistenceAdapter.adapter()

    PersistenceRetry.with_retry(
      fn ->
        adapter.create_flow_node_instance(%{
          id: flow_node_instance_id,
          process_instance_id: data.process_instance_id,
          flow_node_id: handler_node.id,
          flow_node_type: Atom.to_string(handler_node.type),
          event_type: nil,
          lane_name: lane_name,
          state: "active",
          started_at: DateTime.utc_now(),
          input_token: token.payload,
          previous_flow_node_instance_ids: [throw_fni_id],
          type_properties: extra_type_properties
        })
      end,
      "FNI comp handler create #{flow_node_instance_id}"
    )
  end

  defp spawn_handler_task(
         data,
         flow_node_instance_id,
         handler_node,
         token,
         throw_fni_id,
         extra_type_properties
       ) do
    process_instance_pid = self()

    with {:ok, handler_module} <- HandlerDispatch.handler_for(handler_node),
         handler_context =
           build_handler_context(data, flow_node_instance_id, handler_node, process_instance_pid),
         {:ok, task_pid} <-
           Task.Supervisor.start_child(data.task_supervisor, fn ->
             result =
               BoundaryAwareHandler.wrap_enter(
                 handler_module,
                 handler_node,
                 token,
                 handler_context
               )

             dispatch_handler_result(process_instance_pid, flow_node_instance_id, result)
           end) do
      Process.monitor(task_pid)

      entry = %{
        pid: task_pid,
        flow_node_id: handler_node.id,
        flow_node_type: handler_node.type,
        event_type: nil,
        state: :active,
        token: token,
        previous_flow_node_instance_ids: [throw_fni_id],
        type_properties: extra_type_properties,
        next_flow_node_ids: []
      }

      put_in(data.flow_node_instance_states[flow_node_instance_id], entry)
    else
      {:error, reason} ->
        Logger.error(
          "Compensation: handler spawn failed for #{handler_node.id} " <>
            "(FNI #{flow_node_instance_id}): #{inspect(reason)}"
        )

        data
    end
  end

  defp persist_throw_waiting(data, flow_node_instance_id, type_properties, runtime) do
    adapter = PersistenceAdapter.adapter()

    _retry_result =
      PersistenceRetry.with_retry(
        fn ->
          adapter.update_flow_node_instance(flow_node_instance_id, :update_waiting, %{
            state: "waiting",
            type_properties: type_properties
          })
        end,
        "FNI comp throw waiting #{flow_node_instance_id}"
      )

    runtime.emit_fni_state_changed.(
      data,
      flow_node_instance_id,
      Map.get(data.flow_node_instance_states, flow_node_instance_id),
      :active,
      :waiting
    )
  end

  defp persist_throw_finished(data, flow_node_instance_id, _runtime) do
    adapter = PersistenceAdapter.adapter()

    _retry_result =
      PersistenceRetry.with_retry(
        fn ->
          adapter.update_flow_node_instance(flow_node_instance_id, :update_finished, %{
            state: "finished",
            finished_at: DateTime.utc_now()
          })
        end,
        "FNI comp throw finished #{flow_node_instance_id}"
      )

    entry = Map.get(data.flow_node_instance_states, flow_node_instance_id)

    if entry do
      emit_throw_finished(data, flow_node_instance_id, entry)
    end
  end

  defp emit_throw_finished(data, flow_node_instance_id, entry) do
    flow_node =
      Enum.find(data.process_model.flow_nodes, fn node -> node.id == entry.flow_node_id end)

    EngineEventBus.publish(%Event.FlowNodeInstanceFinished{
      flow_node_instance_id: flow_node_instance_id,
      process_instance_id: data.process_instance_id,
      root_process_instance_id: data.root_process_instance_id,
      flow_node_id: entry.flow_node_id,
      flow_node_type: entry.flow_node_type,
      event_type: if(flow_node, do: extract_event_type(flow_node)),
      lane_name: resolve_lane_name(data.process_model, flow_node),
      terminal_state: :finished,
      triggerer_flow_node_instance_id: nil,
      type_properties: entry.type_properties || %{},
      error_info: nil,
      multi_instance_id: Map.get(entry, :multi_instance_id),
      iteration_index: Map.get(entry, :iteration_index),
      occurred_at: DateTime.utc_now()
    })
  end
end
