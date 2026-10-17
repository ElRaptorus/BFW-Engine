defmodule BfwEngine.Execution.ProcessInstance.CompensationOrchestrator do
  @moduledoc """
  Compensation run planner and runtime dispatcher.

  Builds the LIFO handler queue (`build_run/4`) and, when invoked from the
  Process Instance `:gen_statem`, persists and spawns compensation handler
  FNIs. The PI keeps thin wrappers that pass a `runtime` callback map for
  helpers that remain private on the Process Instance (event emission and
  successor FNI dispatch).
  """

  require Logger

  alias BfwEngine.BPMN.Model.EventDefinition
  alias BfwEngine.BPMN.Model.FlowNode
  alias BfwEngine.BPMN.Model.FlowNodeData
  alias BfwEngine.Execution.CompensationResolver
  alias BfwEngine.Execution.ProcessInstance
  alias BfwEngine.Execution.ProcessInstance.FlowNodeLookup
  alias BfwEngine.Execution.ProcessInstance.HandlerDispatch, as: InstanceHandlerDispatch
  alias BfwEngine.Execution.ProcessInstance.JsonSafe
  alias BfwEngine.Execution.ProcessInstance.LaneResolution
  alias BfwEngine.Execution.UuidV7

  alias BfwEngine.Execution.BoundaryAwareHandler
  alias BfwEngine.Execution.HandlerDispatch
  alias BfwEngine.Execution.Persistence, as: PersistenceAdapter
  alias BfwEngine.Execution.PersistenceRetry
  alias BfwEngine.Execution.TaskInboxEvents
  alias BfwEngine.Types.Event
  alias BfwEngine.Types.Token

  @type compensation_target :: %{
          required(:completed_fni_id) => String.t(),
          required(:flow_node_id) => String.t(),
          required(:handler_activity_id) => String.t() | nil,
          required(:token_snapshot) => map(),
          required(:completion_order) => non_neg_integer(),
          optional(:kind) => :handler | :scope,
          optional(:child_process_instance_id) => String.t(),
          optional(:subprocess_node_id) => String.t()
        }

  @type compensation_run :: %{
          queue: [compensation_target()],
          cursor: non_neg_integer(),
          mode: :broadcast | :single | :esp,
          throw_type: :throw | :end | :cancel | :scope,
          outgoing_flow_node_ids: [String.t()],
          token_payload: map(),
          handler_count: non_neg_integer()
        }

  @type scope_child :: %{
          run_key: String.t(),
          target: compensation_target(),
          monitor_ref: reference(),
          busy: boolean()
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
          :throw | :end | :cancel | :scope,
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
      token_payload: token_payload,
      handler_count: 0
    }
  end

  @doc """
  Builds a run that continues after a restart or in a compensation scope
  instance: the target of the in-flight handler (`in_flight_target_id`, or
  `nil`) first, then every target no handler has claimed
  (`claimed_target_ids/1`). `handler_count` starts at the number of handlers
  that already finished for `run_key`.
  """
  @spec build_resumed_run(
          map(),
          String.t(),
          [compensation_target()],
          String.t() | nil,
          :throw | :end | :cancel | :scope,
          [String.t()],
          map()
        ) :: compensation_run()
  def build_resumed_run(
        data,
        run_key,
        targets,
        in_flight_target_id,
        throw_type,
        outgoing_flow_node_ids,
        token_payload
      ) do
    claimed_target_ids = data |> claimed_target_ids() |> MapSet.delete(in_flight_target_id)

    {in_flight, remaining} =
      targets
      |> Enum.reject(&MapSet.member?(claimed_target_ids, &1.completed_fni_id))
      |> Enum.split_with(&(&1.completed_fni_id == in_flight_target_id))

    finished_handler_count =
      Enum.count(data.flow_node_instance_states, fn {_id, entry} ->
        entry.state == :finished and
          link_property(entry.type_properties, :compensation_throw_fni_id) == run_key
      end)

    %{
      build_run(in_flight ++ remaining, throw_type, outgoing_flow_node_ids, token_payload)
      | handler_count: finished_handler_count
    }
  end

  @doc """
  The compensation registry entry for a finished flow node instance, or
  `nil` when its activity is not compensable.

  An activity is compensable when a Compensation Boundary Event links it to a
  handler, or when it is an embedded subprocess (also a transaction or
  ad-hoc subprocess) whose inner activities may be compensable. A
  Multi-Instance or Standard Loop iteration and a compensation handler
  never get an entry of their own; the loop shell stands for its
  iterations. `entry.token.payload` is the activity output.
  """
  @spec registry_entry(map(), String.t(), map(), non_neg_integer()) :: compensation_target() | nil
  def registry_entry(data, flow_node_instance_id, entry, completion_order) do
    node_index = Map.new(data.process_model.flow_nodes, &{&1.id, &1})
    flow_node = Map.get(node_index, entry.flow_node_id)

    if is_nil(Map.get(entry, :multi_instance_id)) and
         is_nil(link_property(entry.type_properties, :compensation_throw_fni_id)) and
         compensable?(flow_node, node_index) do
      %{
        completed_fni_id: flow_node_instance_id,
        flow_node_id: entry.flow_node_id,
        handler_activity_id: compensation_handler_id(flow_node, node_index),
        token_snapshot: entry.token.payload,
        completion_order: completion_order
      }
    end
  end

  @doc """
  Resolves the targets a Compensate Throw or End Event compensates now:
  the registry entries its event definition selects, expanded into handler
  and scope targets (`expand_targets/2`), minus every target another handler
  already claimed or another run has queued.
  """
  @spec resolve_targets(map(), EventDefinition.Compensation.t()) :: [compensation_target()]
  def resolve_targets(data, event_definition) do
    claimed = claimed_target_ids(data)

    data.compensation_registry
    |> CompensationResolver.resolve(event_definition)
    |> then(&expand_targets(data, &1))
    |> Enum.reject(&MapSet.member?(claimed, &1.completed_fni_id))
  end

  @doc """
  Ids of the flow node instances that are compensated already or about to
  be: the `compensation_for` of every handler instance that is `:finished`,
  `:active` or `:waiting`, and every target queued in a compensation run.
  A handler that ended `:fatal`, `:aborted`, `:error` or `:interrupted`
  does not claim its target, so a retry runs that handler again. A scope
  target is never claimed: its scope instance skips what it compensated
  already.
  """
  @spec claimed_target_ids(map()) :: MapSet.t(String.t())
  def claimed_target_ids(data) do
    handled_ids =
      for {_id, entry} <- data.flow_node_instance_states,
          entry.state in [:finished, :active, :waiting],
          link_property(entry.type_properties, :compensation_throw_fni_id) != nil,
          do: link_property(entry.type_properties, :compensation_for)

    queued_ids =
      data.compensation_runs
      |> Map.values()
      |> Enum.flat_map(& &1.queue)
      |> Enum.map(& &1.completed_fni_id)

    MapSet.new(handled_ids ++ queued_ids)
  end

  @doc """
  Expands registry entries into handler and scope targets, in the order
  given.

  An activity with its own compensation handler is one handler target (a
  subprocess with a handler is compensated as a whole). A finished loop
  shell expands into its finished iterations, latest completion first, each
  one a target of its own. An embedded subprocess (also a transaction or
  ad-hoc subprocess) without a handler is one scope target (`kind: :scope`)
  naming its child instance: that instance compensates its inner activities
  in its own scope (BPMN 2.0 §13.5.5, `start_scope_run/2`). Iterations are
  read from persistence, so the expansion is the same before and after a
  restart. A Call Activity without a handler expands into nothing.
  """
  @spec expand_targets(map(), [compensation_target()]) :: [compensation_target()]
  def expand_targets(data, registry_entries) do
    node_index = Map.new(data.process_model.flow_nodes, &{&1.id, &1})

    Enum.flat_map(registry_entries, fn registry_entry ->
      flow_node = Map.get(node_index, registry_entry.flow_node_id)
      entry = Map.get(data.flow_node_instance_states, registry_entry.completed_fni_id, %{})

      instance = %{
        id: registry_entry.completed_fni_id,
        flow_node_id: registry_entry.flow_node_id,
        output_token: registry_entry.token_snapshot,
        type_properties: Map.get(entry, :type_properties) || %{},
        completion_order: registry_entry.completion_order
      }

      expand_activity(data, instance, flow_node, node_index)
    end)
  end

  @doc """
  Starts the compensation run of a compensation scope instance
  (`data.compensation_scope.request`): its registry in LIFO order, expanded, minus
  claimed targets, with the target of an in-flight handler first. The run is
  stored under the request's `anchor_fni_id`. Without an in-flight handler
  the first target is dispatched at once; an empty run replies to the
  requester at once.
  """
  @spec start_scope_run(map(), runtime()) :: map()
  def start_scope_run(%{compensation_scope: %{request: request}} = data, runtime) do
    in_flight_target_id = live_handler_target(data)

    targets =
      data.compensation_registry
      |> Enum.sort_by(& &1.completion_order, :desc)
      |> then(&expand_targets(data, &1))

    run =
      build_resumed_run(
        data,
        request.anchor_fni_id,
        targets,
        in_flight_target_id,
        :scope,
        [],
        %{}
      )

    data = put_in(data.compensation_runs[request.anchor_fni_id], run)

    if in_flight_target_id == nil do
      dispatch_next_handler(data, request.anchor_fni_id, runtime)
    else
      data
    end
  end

  @doc """
  Removes the scope child that compensates `scope_target_id` from
  `data.compensation_scope.children` and drops its monitor. Returns
  `{scope_child, data}`, or `{nil, data}` when no child compensates that
  target.
  """
  @spec take_scope_child(map(), String.t()) :: {scope_child() | nil, map()}
  def take_scope_child(data, scope_target_id) do
    case Enum.find(data.compensation_scope.children, fn {_pid, scope_child} ->
           scope_child.target.completed_fni_id == scope_target_id
         end) do
      nil ->
        {nil, data}

      {pid, scope_child} ->
        Process.demonitor(scope_child.monitor_ref, [:flush])
        {scope_child, update_in(data.compensation_scope.children, &Map.delete(&1, pid))}
    end
  end

  @doc """
  Continues the run of a scope child that replied: adds the `handler_count`
  it reported and advances the run, when the run still waits for that
  child's target. A stale reply changes nothing.
  """
  @spec finish_scope_target(map(), scope_child(), non_neg_integer(), runtime()) :: map()
  def finish_scope_target(data, scope_child, handler_count, runtime) do
    if waits_for?(data, scope_child) do
      advance_run(data, scope_child.run_key, handler_count, runtime)
    else
      data
    end
  end

  @doc """
  Starts the scope target of a scope child again after the instance that
  was still running it (`busy: true`) stopped.
  """
  @spec retry_scope_target(map(), scope_child(), runtime()) :: map()
  def retry_scope_target(data, scope_child, runtime) do
    if waits_for?(data, scope_child) do
      dispatch_next_handler(data, scope_child.run_key, runtime)
    else
      data
    end
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
    claimed = claimed_target_ids(data)

    targets =
      data.compensation_registry
      |> Enum.sort_by(& &1.completion_order, :desc)
      |> then(&expand_targets(data, &1))
      |> Enum.reject(&MapSet.member?(claimed, &1.completed_fni_id))

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
  Advance the run cursor after its current target finished and dispatch
  the next. `finished_handler_count` is added to the run's `handler_count`:
  1 for a handler FNI, the reported count for a scope target.
  """
  @spec advance_run(map(), String.t(), non_neg_integer(), runtime()) :: map()
  def advance_run(data, throw_fni_id, finished_handler_count, runtime) do
    case Map.get(data.compensation_runs, throw_fni_id) do
      nil ->
        data

      run ->
        run = %{advance_cursor(run) | handler_count: run.handler_count + finished_handler_count}
        data = put_in(data.compensation_runs[throw_fni_id], run)

        # A scope instance's run key is its requester's throw FNI.
        data =
          case Map.get(data.flow_node_instance_states, throw_fni_id) do
            nil ->
              data

            throw_entry ->
              cursor_properties = Map.merge(throw_entry.type_properties, %{cursor: run.cursor})

              put_in(
                data.flow_node_instance_states[throw_fni_id],
                %{throw_entry | type_properties: cursor_properties}
              )
          end

        dispatch_next_handler(data, throw_fni_id, runtime)
    end
  end

  @doc """
  Continue a run rebuilt on resume that has no live handler: dispatch the
  handler at the cursor, or complete the run when no target is left.
  """
  @spec resume_run(map(), String.t(), runtime()) :: map()
  def resume_run(data, throw_fni_id, runtime) do
    dispatch_next_handler(data, throw_fni_id, runtime)
  end

  @spec dispatch_next_handler(map(), String.t(), runtime()) :: map()
  defp dispatch_next_handler(data, throw_fni_id, runtime) do
    run = Map.fetch!(data.compensation_runs, throw_fni_id)

    case current_target(run) do
      nil -> finish_run(data, throw_fni_id, run, runtime)
      %{kind: :scope} = target -> dispatch_scope_target(data, throw_fni_id, run, target, runtime)
      target -> dispatch_handler_target(data, throw_fni_id, run, target, runtime)
    end
  end

  defp dispatch_handler_target(data, throw_fni_id, run, target, runtime) do
    handler_node = FlowNodeLookup.find_flow_node(data, target.handler_activity_id)

    if handler_node == nil do
      Logger.warning(
        "Compensation handler activity #{target.handler_activity_id} not found in model, " <>
          "skipping for throw FNI #{throw_fni_id}"
      )

      data = put_in(data.compensation_runs[throw_fni_id], advance_cursor(run))
      dispatch_next_handler(data, throw_fni_id, runtime)
    else
      handler_token = %Token{
        id: UuidV7.generate(),
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

  # Runs also start from `init/1` on resume, where starting a sibling under
  # the same DynamicSupervisor would deadlock.
  defp dispatch_scope_target(data, run_key, _run, target, _runtime) do
    send(self(), {:compensation_scope_dispatch, run_key, target})
    data
  end

  @doc """
  Starts the scope instance for the scope target `dispatch_scope_target`
  queued for run `run_key`, unless the run no longer waits for it. The
  instance replies to this process (see
  `ProcessInstance.start_compensation_scope/2`).
  """
  @spec start_scope_target(map(), String.t(), compensation_target(), runtime()) :: map()
  def start_scope_target(data, run_key, target, runtime) do
    if waits_for?(data, %{run_key: run_key, target: target}) do
      request = %{
        anchor_fni_id: run_key,
        scope_target_id: target.completed_fni_id,
        subprocess_node_id: target.subprocess_node_id,
        root_process_instance_id: data.root_process_instance_id,
        reply_to: self()
      }

      target.child_process_instance_id
      |> ProcessInstance.start_compensation_scope(request)
      |> track_scope_start(data, run_key, target, runtime)
    else
      data
    end
  end

  defp track_scope_start({:ok, pid}, data, run_key, target, _runtime),
    do: track_scope_child(data, pid, run_key, target, false)

  defp track_scope_start({:busy, pid}, data, run_key, target, _runtime),
    do: track_scope_child(data, pid, run_key, target, true)

  defp track_scope_start({:error, :not_found}, data, run_key, target, runtime) do
    Logger.warning(
      "Compensation: child instance #{target.child_process_instance_id} of subprocess " <>
        "#{target.flow_node_id} no longer exists, its inside is not compensated " <>
        "for throw FNI #{run_key}"
    )

    data = update_in(data.compensation_runs[run_key], &advance_cursor/1)
    dispatch_next_handler(data, run_key, runtime)
  end

  defp track_scope_start({:error, reason}, data, _run_key, target, _runtime) do
    send(self(), {:compensation_scope_start_failed, target, reason})
    data
  end

  defp track_scope_child(data, pid, run_key, target, busy) do
    scope_child = %{
      run_key: run_key,
      target: target,
      monitor_ref: Process.monitor(pid),
      busy: busy
    }

    put_in(data.compensation_scope.children[pid], scope_child)
  end

  defp waits_for?(data, scope_child) do
    with %{} = run <- Map.get(data.compensation_runs, scope_child.run_key),
         %{completed_fni_id: current_target_id} <- current_target(run) do
      current_target_id == scope_child.target.completed_fni_id
    else
      _no_run_or_target -> false
    end
  end

  defp live_handler_target(data) do
    Enum.find_value(data.flow_node_instance_states, fn {_id, entry} ->
      if entry.state in [:active, :waiting] and
           link_property(entry.type_properties, :compensation_throw_fni_id) != nil do
        link_property(entry.type_properties, :compensation_for)
      end
    end)
  end

  @doc """
  Complete a compensation run: persist the throw FNI as finished and
  dispatch its outgoing sequence flows (`:throw`), set
  `compensation_end_reached` (`:end`), set `cancel_reached` and keep the
  run's handler count on the Cancel End Event entry as
  `:compensation_handler_count` (`:cancel`), or reply
  `{:compensation_scope_finished, process_instance_id, scope_target_id,
  handler_count}` to the requester of a scope instance (`:scope`).
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
          id: UuidV7.generate(),
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
        states =
          Map.update!(data.flow_node_instance_states, throw_fni_id, fn cancel_entry ->
            type_properties = Map.get(cancel_entry, :type_properties) || %{}

            %{
              cancel_entry
              | type_properties:
                  Map.put(type_properties, :compensation_handler_count, run.handler_count)
            }
          end)

        %{data | cancel_reached: true, flow_node_instance_states: states}

      :scope ->
        request = data.compensation_scope.request

        send(
          request.reply_to,
          {:compensation_scope_finished, data.process_instance_id, request.scope_target_id,
           run.handler_count}
        )

        data
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
    flow_node_instance_id = UuidV7.generate()
    lane_name = LaneResolution.resolve_lane_name(data.process_model, handler_node)

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
           InstanceHandlerDispatch.build_handler_context(
             data,
             flow_node_instance_id,
             handler_node,
             process_instance_pid
           ),
         :ok <-
           InstanceHandlerDispatch.register_service_task_completion_route(
             handler_node,
             flow_node_instance_id,
             nil
           ),
         {:ok, task_pid} <-
           Task.Supervisor.start_child(data.task_supervisor, fn ->
             result =
               BoundaryAwareHandler.wrap_enter(
                 handler_module,
                 handler_node,
                 token,
                 handler_context
               )

             InstanceHandlerDispatch.dispatch_handler_result(
               process_instance_pid,
               flow_node_instance_id,
               result
             )
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
    entry = Map.get(data.flow_node_instance_states, flow_node_instance_id)

    output_token =
      case entry do
        %{token: %{payload: payload}} -> JsonSafe.convert(payload) || %{}
        _ -> %{}
      end

    adapter = PersistenceAdapter.adapter()

    persist_result =
      PersistenceRetry.with_retry(
        fn ->
          adapter.update_flow_node_instance(flow_node_instance_id, :update_finished, %{
            state: "finished",
            finished_at: DateTime.utc_now(),
            output_token: output_token
          })
        end,
        "FNI comp throw finished #{flow_node_instance_id}"
      )

    if entry do
      emit_throw_finished(data, flow_node_instance_id, entry, persist_result)
    end
  end

  defp expand_activity(data, instance, flow_node, node_index) do
    if loop_activity?(flow_node) do
      data.process_instance_id
      |> persisted_instances()
      |> Enum.filter(&(Map.get(&1, :multi_instance_id) == instance.id and finished_instance?(&1)))
      |> sort_latest_completion_first()
      |> Enum.flat_map(&expand_instance(&1, flow_node, node_index))
    else
      expand_instance(instance, flow_node, node_index)
    end
  end

  defp expand_instance(instance, flow_node, node_index) do
    case compensation_handler_id(flow_node, node_index) do
      nil ->
        scope_targets(instance, flow_node)

      handler_activity_id ->
        [
          %{
            completed_fni_id: instance.id,
            flow_node_id: instance.flow_node_id,
            handler_activity_id: handler_activity_id,
            token_snapshot: instance.output_token || %{},
            completion_order: Map.get(instance, :completion_order, 0)
          }
        ]
    end
  end

  defp scope_targets(instance, %FlowNode{} = flow_node) do
    with true <- propagating_subprocess?(flow_node),
         child_process_instance_id when is_binary(child_process_instance_id) <-
           link_property(instance.type_properties, :child_process_instance_id) do
      [
        %{
          kind: :scope,
          completed_fni_id: instance.id,
          flow_node_id: instance.flow_node_id,
          child_process_instance_id: child_process_instance_id,
          subprocess_node_id: flow_node.id,
          handler_activity_id: nil,
          token_snapshot: instance.output_token || %{},
          completion_order: Map.get(instance, :completion_order, 0)
        }
      ]
    else
      _not_propagating -> []
    end
  end

  defp scope_targets(_instance, nil), do: []

  defp persisted_instances(process_instance_id) do
    case PersistenceRetry.with_retry(
           fn ->
             PersistenceAdapter.adapter().list_all_flow_node_instances(process_instance_id)
           end,
           "FNI list for compensation #{process_instance_id}"
         ) do
      {:ok, instances} ->
        instances

      {:error, reason} ->
        Logger.error(
          "Compensation: flow node instances of #{process_instance_id} could not be read, " <>
            "its activities are not compensated: #{inspect(reason)}"
        )

        []
    end
  end

  defp finished_instance?(instance), do: instance.state in ["finished", :finished]

  defp sort_latest_completion_first(instances) do
    Enum.sort_by(
      instances,
      &(Map.get(&1, :finished_at) || Map.get(&1, :started_at)),
      {:desc, DateTime}
    )
  end

  defp compensable?(nil, _node_index), do: false

  defp compensable?(%FlowNode{} = flow_node, node_index) do
    compensation_handler_id(flow_node, node_index) != nil or propagating_subprocess?(flow_node)
  end

  defp propagating_subprocess?(%FlowNode{
         type: :sub_process,
         type_data: %FlowNodeData.SubProcess{triggered_by_event: false}
       }),
       do: true

  defp propagating_subprocess?(_flow_node), do: false

  defp loop_activity?(%FlowNode{multi_instance: multi_instance, standard_loop: standard_loop}),
    do: multi_instance != nil or standard_loop != nil

  defp loop_activity?(nil), do: false

  defp compensation_handler_id(nil, _node_index), do: nil

  defp compensation_handler_id(%FlowNode{} = flow_node, node_index) do
    Enum.find_value(flow_node.boundary_event_refs || [], fn boundary_ref ->
      case Map.get(node_index, boundary_ref) do
        %FlowNode{
          type: :boundary_event,
          type_data: %FlowNodeData.BoundaryEvent{
            event_definition: %EventDefinition.Compensation{},
            compensation_handler_id: handler_id
          }
        }
        when handler_id != nil ->
          handler_id

        _other_boundary ->
          nil
      end
    end)
  end

  defp link_property(nil, _key), do: nil

  defp link_property(type_properties, key) do
    Map.get(type_properties, key) || Map.get(type_properties, Atom.to_string(key))
  end

  defp emit_throw_finished(data, flow_node_instance_id, entry, persist_result) do
    flow_node =
      Enum.find(data.process_model.flow_nodes, fn node -> node.id == entry.flow_node_id end)

    TaskInboxEvents.publish_committed_finish(
      persist_result,
      %Event.FlowNodeInstanceFinished{
        flow_node_instance_id: flow_node_instance_id,
        process_instance_id: data.process_instance_id,
        root_process_instance_id: data.root_process_instance_id,
        flow_node_id: entry.flow_node_id,
        flow_node_type: entry.flow_node_type,
        event_type: if(flow_node, do: FlowNodeLookup.extract_event_type(flow_node)),
        lane_name: LaneResolution.resolve_lane_name(data.process_model, flow_node),
        terminal_state: :finished,
        triggerer_flow_node_instance_id: nil,
        type_properties: entry.type_properties || %{},
        error_info: nil,
        multi_instance_id: Map.get(entry, :multi_instance_id),
        iteration_index: Map.get(entry, :iteration_index),
        occurred_at: DateTime.utc_now()
      },
      flow_node
    )
  end
end
