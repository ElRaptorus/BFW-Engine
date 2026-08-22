defmodule EvilEngine.Execution do
  @moduledoc """
  Public API for the engine runtime.

  All external callers (API layer, plugins) use this module to start
  process instances and interact with waiting user tasks. Internally
  it looks up PI processes via the Registry and forwards calls.
  """

  require Logger

  alias EvilEngine.BPMN.ModelCache
  alias EvilEngine.Events.EngineEventBus
  alias EvilEngine.Execution.Persistence
  alias EvilEngine.Execution.PersistenceRetry
  alias EvilEngine.Execution.ProcessInstance
  alias EvilEngine.Types.Event

  @typedoc false
  @type engine_capacity_info :: %{
          required(:active) => non_neg_integer(),
          required(:limit) => non_neg_integer() | :infinity
        }

  @doc """
  Start a new process instance.

  On success returns `{:ok, pid}`. When `:max_concurrent_process_instances` is configured and the active PI count has reached the cap, returns
  `{:error, :engine_at_capacity, %{active: count, limit: configured_cap}}`
  **before** the supervisor is touched.

  The cap is enforced as a soft client-side pre-check here, NOT on the
  underlying `DynamicSupervisor` (which runs with `max_children: :infinity`
  so `ResumeRunner` can revive every `:running` PI at boot regardless of
  capacity). This is a deliberate v1 choice — see
  [`docs/architecture/execution.md`](../../../docs/architecture/execution.md)
  Resume on Startup. The check is "soft" in that brief overshoot is
  possible under concurrent starts (TOCTOU between `count_active/0` and
  `start_child/2`); for v1 PoC scale this is acceptable.

  ## Options

  - `:process_instance_id` — pre-generated PI ID (required).
  - `:process_version_id` — the deployed process version to execute (required).
  - `:start_event_id` — optional Start Event ID for disambiguation.
  - `:payload` — initial token payload (map or nil).
  - `:identity` — `%Identity{}` of the initiator (required).
  - `:business_key` — optional external business key.
  - `:parent_process_instance_id` — for Call Activity / SubProcess child PIs.
  - `:triggerer_flow_node_instance_id` — for Call Activity / SubProcess child PIs.
  - `:subprocess_node_id` — internal only; selects the synthetic inner-scope
    model for an embedded/event/transactional subprocess. Requires
    `:parent_process_instance_id` (see the isolation invariant below).

  ## Subprocess start isolation

  A Start Event nested inside a subprocess is addressable only through an
  internal child spawn, which always carries a `:parent_process_instance_id`.
  Therefore a `:subprocess_node_id` without a parent means an external caller
  (REST/plugin) tried to start an inner scope directly; such calls are rejected
  with `{:error, :orphan_subprocess_start}` before the PI is ever supervised.
  """
  @spec start_process_instance(ProcessInstance.start_opts()) ::
          {:ok, pid()}
          | {:error, term()}
          | {:error, :orphan_subprocess_start}
          | {:error, :engine_at_capacity, engine_capacity_info()}
  def start_process_instance(opts) do
    with :ok <- validate_subprocess_parent(opts),
         :ok <- check_capacity() do
      case DynamicSupervisor.start_child(
             EvilEngine.Execution.Supervisor,
             {ProcessInstance, opts}
           ) do
        {:ok, pid} ->
          {:ok, pid}

        # Defensive fallback — the supervisor runs with `max_children: :infinity`
        # so this branch is unreachable in production. Kept so the error-shape
        # contract holds if the supervisor configuration is ever changed.
        {:error, :max_children} ->
          {:error, :engine_at_capacity, %{active: count_active(), limit: configured_limit()}}

        error ->
          error
      end
    end
  end

  defp check_capacity do
    case configured_limit() do
      :infinity ->
        :ok

      limit when is_integer(limit) ->
        active = count_active()

        if active >= limit do
          {:error, :engine_at_capacity, %{active: active, limit: limit}}
        else
          :ok
        end
    end
  end

  # Subprocess start isolation invariant. Every legitimate inner-scope spawn
  # (Call Activity, embedded/event/transactional SubProcess) is initiated by a
  # handler that sets `:parent_process_instance_id`. A `:subprocess_node_id`
  # present without a parent can only originate from an external caller trying to
  # start a nested Start Event directly, which must never be possible.
  defp validate_subprocess_parent(opts) do
    if not is_nil(opts[:subprocess_node_id]) and is_nil(opts[:parent_process_instance_id]) do
      {:error, :orphan_subprocess_start}
    else
      :ok
    end
  end

  @doc false
  @spec count_active() :: non_neg_integer()
  def count_active do
    %{active: count} = DynamicSupervisor.count_children(EvilEngine.Execution.Supervisor)
    count
  end

  @doc false
  @spec configured_limit() :: non_neg_integer() | :infinity
  def configured_limit do
    Application.get_env(:core_execution, :max_concurrent_process_instances, :infinity)
  end

  @doc """
  Complete a waiting User Task / Manual Task.

  The caller must provide the `process_instance_id` to locate the PI
  process. The API layer resolves this from the FNI's DB row.
  """
  @spec finish_user_task(String.t(), String.t(), term(), EvilEngine.Types.Identity.t()) ::
          :ok | {:error, term()} | {:error, :payload_too_large, map()}
  def finish_user_task(process_instance_id, flow_node_instance_id, result, identity) do
    with {:ok, process_instance_pid} <- lookup_process_instance(process_instance_id) do
      ProcessInstance.finish_user_task(
        process_instance_pid,
        flow_node_instance_id,
        result,
        identity
      )
    end
  catch
    :exit, _ -> {:error, :not_found}
  end

  @doc """
  Cancel a waiting User Task.

  The caller must provide the `process_instance_id` to locate the PI
  process. The API layer resolves this from the FNI's DB row.
  """
  @spec cancel_user_task(String.t(), String.t(), String.t() | nil, EvilEngine.Types.Identity.t()) ::
          :ok | {:error, term()}
  def cancel_user_task(process_instance_id, flow_node_instance_id, reason, identity) do
    with {:ok, process_instance_pid} <- lookup_process_instance(process_instance_id) do
      ProcessInstance.cancel_user_task(
        process_instance_pid,
        flow_node_instance_id,
        reason,
        identity
      )
    end
  catch
    :exit, _ -> {:error, :not_found}
  end

  @doc """
  Abort a running process instance.

  Transitions the PI to `:aborted`, cancels all active FNIs, and stops
  the `gen_statem`. The caller must supply the PI ID and an optional
  abort reason. Authorization is enforced by the API layer.
  """
  @spec abort_process_instance(String.t(), String.t() | nil, EvilEngine.Types.Identity.t() | nil) ::
          :ok | {:error, term()}
  def abort_process_instance(process_instance_id, reason, identity) do
    with {:ok, process_instance_pid} <- lookup_process_instance(process_instance_id) do
      ProcessInstance.abort(process_instance_pid, reason, identity)
    end
  catch
    :exit, _ -> {:error, :not_found}
  end

  @doc """
  Force a running process instance into fatal state (internal cascade only).

  Used by `CallActivity.handle_fatal/1` to cascade fatal from a parent PI
  to the child PI started by the Call Activity.
  """
  @spec fatal_process_instance(String.t(), map()) :: :ok | {:error, term()}
  def fatal_process_instance(process_instance_id, reason) do
    with {:ok, process_instance_pid} <- lookup_process_instance(process_instance_id) do
      ProcessInstance.force_fatal(process_instance_pid, reason)
    end
  catch
    :exit, _ -> {:error, :not_found}
  end

  @doc """
  Complete a waiting async Service Task FNI with a result payload.

  Called by plugins via `engine_facade.finish_async_service_task/2`.
  The PI process is found via the FNI's registration in the Execution Registry.
  """
  @spec finish_async_service_task(String.t(), term()) :: :ok | {:error, term()}
  def finish_async_service_task(flow_node_instance_id, result) do
    with {:ok, process_instance_pid} <-
           lookup_process_instance_for_flow_node_instance(flow_node_instance_id) do
      ProcessInstance.finish_async_service_task(
        process_instance_pid,
        flow_node_instance_id,
        result
      )
    end
  catch
    :exit, _ -> {:error, :process_instance_not_found}
  end

  @doc """
  Fail a waiting async Service Task FNI with an error code and message.

  Called by plugins via `engine_facade.fail_async_service_task/3`.
  """
  @spec fail_async_service_task(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def fail_async_service_task(flow_node_instance_id, error_code, error_message) do
    with {:ok, process_instance_pid} <-
           lookup_process_instance_for_flow_node_instance(flow_node_instance_id) do
      ProcessInstance.fail_async_service_task(
        process_instance_pid,
        flow_node_instance_id,
        error_code,
        error_message
      )
    end
  catch
    :exit, _ -> {:error, :process_instance_not_found}
  end

  defp lookup_process_instance_for_flow_node_instance(flow_node_instance_id) do
    case Registry.lookup(EvilEngine.Execution.Registry, {:fni, flow_node_instance_id}) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :process_instance_not_found}
    end
  end

  @doc """
  Manually trigger a waiting timer event FNI.

  The Api layer has already validated type, state, and lane access.
  This function looks up the PI process and asks it to fire the timer.
  """
  @spec trigger_timer_event(String.t(), String.t()) :: :ok | {:error, term()}
  def trigger_timer_event(process_instance_id, flow_node_instance_id) do
    with {:ok, process_instance_pid} <- lookup_process_instance(process_instance_id) do
      ProcessInstance.trigger_timer_event(process_instance_pid, flow_node_instance_id)
    end
  catch
    :exit, _ -> {:error, :not_found}
  end

  @doc "Look up a PI process by its process_instance_id."
  @spec lookup_process_instance(String.t()) :: {:ok, pid()} | {:error, :not_found}
  def lookup_process_instance(process_instance_id) do
    case Registry.lookup(EvilEngine.Execution.Registry, process_instance_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end

  # ---------------------------------------------------------------------------
  # Ad-hoc subprocess operations
  # ---------------------------------------------------------------------------

  @doc """
  Activate an inner activity within a running ad-hoc subprocess child PI.

  Returns `{:ok, %{flow_node_instance_id: id}}` on success.
  """
  @spec activate_adhoc_activity(String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def activate_adhoc_activity(child_process_instance_id, flow_node_id) do
    with {:ok, pid} <- lookup_process_instance(child_process_instance_id) do
      :gen_statem.call(pid, {:activate_adhoc_activity_sync, flow_node_id})
    end
  catch
    :exit, _ -> {:error, :adhoc_not_active}
  end

  @doc """
  Signal the completion of an ad-hoc subprocess child PI.

  The child PI will finish once all active/waiting FNIs complete.
  """
  @spec signal_adhoc_completion(String.t()) :: :ok | {:error, term()}
  def signal_adhoc_completion(child_process_instance_id) do
    with {:ok, pid} <- lookup_process_instance(child_process_instance_id) do
      :gen_statem.call(pid, :signal_adhoc_completion_sync)
    end
  catch
    :exit, _ -> {:error, :adhoc_not_active}
  end

  @doc """
  Query the enabled/performed inner activities of an ad-hoc child PI.
  """
  @spec get_adhoc_enabled_activities(String.t()) ::
          {:ok, [map()]} | {:error, term()}
  def get_adhoc_enabled_activities(child_process_instance_id) do
    with {:ok, pid} <- lookup_process_instance(child_process_instance_id) do
      :gen_statem.call(pid, :get_adhoc_enabled_activities)
    end
  catch
    :exit, _ -> {:error, :not_found}
  end

  @doc """
  Query the runtime status of an ad-hoc subprocess child PI.
  """
  @spec get_adhoc_status(String.t()) :: {:ok, map()} | {:error, term()}
  def get_adhoc_status(child_process_instance_id) do
    with {:ok, pid} <- lookup_process_instance(child_process_instance_id) do
      :gen_statem.call(pid, :get_adhoc_status)
    end
  catch
    :exit, _ -> {:error, :not_found}
  end

  # ---------------------------------------------------------------------------
  # Retry orchestration
  # ---------------------------------------------------------------------------

  @doc """
  Execute a retry for a pre-validated process instance.

  Called by `EvilEngine.Api.retry_process_instance/3` after the targeted PI
  has been validated (exists, is terminal, not running, version resolved).

  Discovers the PI tree structure, validates root eligibility (§1.10.1
  Rule A), and executes the three-phase retry mechanism:
  Phase 1 (targeted reset), Phase 2 (tree reset), Phase 3 (resume from root).

  Receives a keyword list with:
    - `:pi_data` (required) — targeted PI's data (pre-loaded + validated by Api)
    - `:resolved_version_id` (required) — target version UUID (resolved by Api)
    - `:identity` (required) — retrying user's Identity
    - `:reset_to_flow_node_instance_id` (optional) — checkpoint FNI ID
  """
  @spec retry_process_instance(keyword()) ::
          :ok
          | {:error, term()}
          | {:error, atom(), term()}
          | {:error, atom(), term(), term()}
  def retry_process_instance(opts) do
    adapter = Persistence.adapter()
    pi_data = Keyword.fetch!(opts, :pi_data)
    resolved_version_id = Keyword.fetch!(opts, :resolved_version_id)
    identity = Keyword.fetch!(opts, :identity)

    with {:ok, root_pi_data, ancestor_chain} <- resolve_tree_context(pi_data, adapter),
         {:ok, all_fnis} <-
           retry_adapter_call(adapter, :list_all_flow_node_instances, [pi_data.id]),
         {:ok, surviving_fnis, deletion_set} <- maybe_apply_checkpoint(all_fnis, opts),
         :ok <-
           validate_fni_compatibility(
             surviving_fnis,
             resolved_version_id,
             pi_data.process_version_id
           ),
         reset_spec <-
           build_reset_spec(surviving_fnis, deletion_set, pi_data, resolved_version_id, opts),
         {:ok, _reactivation_fnis} <-
           retry_adapter_call(adapter, :execute_retry_reset, [pi_data.id, reset_spec]),
         {:ok, reset_ancestors} <- reset_ancestor_chain(ancestor_chain, adapter),
         {:ok, reset_descendants_list} <-
           reset_descendants([pi_data | ancestor_chain], adapter),
         :ok <- check_capacity(),
         {:ok, root_fnis} <-
           retry_adapter_call(adapter, :list_all_flow_node_instances, [root_pi_data.id]) do
      all_resets =
        [{pi_data.id, pi_data.state, pi_data.finished_at} | reset_ancestors] ++
          reset_descendants_list

      start_opts = build_resume_opts(root_pi_data, root_fnis)

      case DynamicSupervisor.start_child(
             EvilEngine.Execution.Supervisor,
             {ProcessInstance, start_opts}
           ) do
        {:ok, _pid} ->
          emit_retry_event(root_pi_data, pi_data, resolved_version_id, identity, opts, root_fnis)
          :ok

        {:error, {:already_started, _existing_pid}} ->
          revert_tree_retry(all_resets, adapter)
          {:error, :process_instance_not_retriable, "running"}

        {:error, reason} ->
          revert_tree_retry(all_resets, adapter)
          {:error, :retry_start_failed, reason}
      end
    end
  end

  defp resolve_tree_context(pi_data, adapter) do
    case pi_data.parent_process_instance_id do
      nil ->
        {:ok, pi_data, []}

      parent_id ->
        walk_ancestors(parent_id, pi_data.triggerer_flow_node_instance_id, adapter, [])
        |> case do
          {:ok, root_pi_data, ancestors} -> {:ok, root_pi_data, ancestors}
          error -> error
        end
    end
  end

  defp walk_ancestors(process_instance_id, child_triggerer_fni_id, adapter, accumulated_chain) do
    case retry_adapter_call(adapter, :get_process_instance_for_retry, [process_instance_id]) do
      {:ok, ancestor_data} ->
        with :ok <- check_triggerer_scope_restrictions(child_triggerer_fni_id, adapter) do
          validate_and_continue_walk(ancestor_data, adapter, accumulated_chain)
        end

      {:error, :not_found} ->
        {:error, :ancestor_not_found, process_instance_id}
    end
  end

  defp check_triggerer_scope_restrictions(nil, _adapter), do: :ok

  defp check_triggerer_scope_restrictions(triggerer_fni_id, adapter) do
    case adapter.get_flow_node_instance_by_id(triggerer_fni_id) do
      {:ok, fni} ->
        type_props = fni.type_properties || %{}

        cond do
          Map.get(type_props, "is_transaction") == true or
              Map.get(type_props, :is_transaction) == true ->
            {:error, :retry_inside_transaction_scope}

          Map.get(type_props, "is_ad_hoc") == true ->
            {:error, :retry_inside_adhoc_subprocess}

          true ->
            :ok
        end

      {:error, :not_found} ->
        :ok
    end
  end

  @retriable_pi_states ["fatal", "aborted", "error"]

  defp validate_and_continue_walk(ancestor_data, adapter, accumulated_chain) do
    if ancestor_data.state in @retriable_pi_states do
      chain = accumulated_chain ++ [ancestor_data]

      case ancestor_data.parent_process_instance_id do
        nil ->
          {:ok, ancestor_data, chain}

        parent_id ->
          walk_ancestors(parent_id, ancestor_data.triggerer_flow_node_instance_id, adapter, chain)
      end
    else
      {:error, :root_process_instance_not_terminal, ancestor_data.state, ancestor_data.id}
    end
  end

  defp maybe_apply_checkpoint(all_fnis, opts) do
    case Keyword.get(opts, :reset_to_flow_node_instance_id) do
      nil -> {:ok, all_fnis, []}
      checkpoint_fni_id -> apply_checkpoint(all_fnis, checkpoint_fni_id)
    end
  end

  defp apply_checkpoint(all_fnis, checkpoint_fni_id) do
    case Enum.find(all_fnis, &(&1.id == checkpoint_fni_id)) do
      nil ->
        {:error, :flow_node_instance_not_found, checkpoint_fni_id}

      checkpoint_fni ->
        cond do
          ebg_loser_fni?(checkpoint_fni) ->
            {:error, :retry_checkpoint_is_ebg_loser}

          join_gateway_fni?(checkpoint_fni, all_fnis) ->
            {:error, :retry_checkpoint_is_join_gateway}

          mi_iteration_fni?(checkpoint_fni) ->
            {:error, :retry_checkpoint_is_mi_iteration}

          non_retryable_fni?(checkpoint_fni) ->
            {:error, :retry_checkpoint_is_non_retryable}

          adhoc_scope_fni?(checkpoint_fni) ->
            {:error, :retry_checkpoint_inside_adhoc_subprocess}

          true ->
            do_apply_checkpoint(all_fnis, checkpoint_fni_id)
        end
    end
  end

  defp ebg_loser_fni?(fni) do
    fni.state in ["aborted", "interrupted"] and
      (Map.get(fni.type_properties, "reason") == "event_based_gateway_sibling_cancelled" or
         Map.get(fni.type_properties, :reason) == "event_based_gateway_sibling_cancelled")
  end

  defp join_gateway_fni?(checkpoint_fni, _all_fnis) do
    checkpoint_fni.flow_node_type in ["parallel_gateway", "inclusive_gateway"]
  end

  defp mi_iteration_fni?(checkpoint_fni) do
    multi_instance_id = Map.get(checkpoint_fni, :multi_instance_id)
    is_binary(multi_instance_id) and multi_instance_id != ""
  end

  @non_retryable_reasons [
    "event_based_gateway_sibling_cancelled",
    "host_completed",
    "sibling_boundary_interrupted",
    "terminated_by_end_event",
    "cancelled_by_cancel_end",
    "adhoc_completion_cancelled"
  ]

  defp non_retryable_fni?(fni) do
    reason =
      Map.get(fni.type_properties || %{}, "reason") ||
        Map.get(fni.type_properties || %{}, :reason)

    reason in @non_retryable_reasons
  end

  defp adhoc_scope_fni?(fni) do
    type_props = fni.type_properties || %{}
    Map.get(type_props, "is_ad_hoc") == true
  end

  defp do_apply_checkpoint(all_fnis, checkpoint_fni_id) do
    forward_adjacency = build_forward_adjacency(all_fnis)
    downstream_ids = bfs_forward(checkpoint_fni_id, forward_adjacency)

    deletion_set = build_deletion_set(all_fnis, downstream_ids)
    deletion_id_set = Map.new(downstream_ids, &{&1, true})

    surviving_fnis =
      Enum.reject(all_fnis, &Map.has_key?(deletion_id_set, &1.id))

    {:ok, surviving_fnis, deletion_set}
  end

  defp build_deletion_set(all_fnis, downstream_ids) do
    fni_index = Map.new(all_fnis, &{&1.id, &1})

    Enum.map(downstream_ids, fn fni_id ->
      fni = Map.fetch!(fni_index, fni_id)
      {fni.id, fni.flow_node_type, fni.type_properties}
    end)
  end

  defp build_forward_adjacency(all_fnis) do
    Enum.reduce(all_fnis, %{}, fn fni, accumulator ->
      Enum.reduce(fni.previous_flow_node_instance_ids || [], accumulator, fn predecessor_id,
                                                                             inner_accumulator ->
        Map.update(inner_accumulator, predecessor_id, [fni.id], &[fni.id | &1])
      end)
    end)
  end

  defp bfs_forward(start_id, forward_adjacency) do
    initial_successors = Map.get(forward_adjacency, start_id, [])
    do_bfs(initial_successors, forward_adjacency, %{}, [])
  end

  defp do_bfs([], _forward_adjacency, _visited, collected), do: collected

  defp do_bfs([current_id | rest], forward_adjacency, visited, collected) do
    if Map.has_key?(visited, current_id) do
      do_bfs(rest, forward_adjacency, visited, collected)
    else
      new_visited = Map.put(visited, current_id, true)
      successors = Map.get(forward_adjacency, current_id, [])

      do_bfs(
        rest ++ successors,
        forward_adjacency,
        new_visited,
        [current_id | collected]
      )
    end
  end

  defp validate_fni_compatibility(_surviving_fnis, version_id, current_version_id)
       when version_id == current_version_id,
       do: :ok

  defp validate_fni_compatibility(surviving_fnis, target_version_id, _current_version_id) do
    case ModelCache.fetch(target_version_id) do
      {:ok, definitions} ->
        check_fni_flow_node_existence(surviving_fnis, definitions)

      {:error, reason} ->
        {:error, :target_version_not_cached, reason}
    end
  end

  defp check_fni_flow_node_existence(surviving_fnis, definitions) do
    target_flow_node_ids =
      definitions.processes
      |> Enum.flat_map(& &1.flow_nodes)
      |> Map.new(&{&1.id, true})

    fnis_to_check =
      Enum.reject(surviving_fnis, &(&1.state in ["finished", "interrupted"]))

    conflicts =
      fnis_to_check
      |> Enum.reject(&Map.has_key?(target_flow_node_ids, &1.flow_node_id))
      |> Enum.map(&%{flow_node_instance_id: &1.id, flow_node_id: &1.flow_node_id})

    if conflicts == [] do
      :ok
    else
      {:error, :version_migration_incompatible, conflicts}
    end
  end

  defp build_reset_spec(surviving_fnis, deletion_set, pi_data, resolved_version_id, opts) do
    reset_fni_ids = compute_reset_fni_ids(surviving_fnis, pi_data, opts)

    spec = %{reset_fni_ids: reset_fni_ids}

    spec =
      if deletion_set != [] do
        Map.put(spec, :delete_fni_ids, deletion_set)
      else
        spec
      end

    if resolved_version_id != pi_data.process_version_id do
      Map.put(spec, :version_id, resolved_version_id)
    else
      spec
    end
  end

  defp compute_reset_fni_ids(surviving_fnis, pi_data, opts) do
    checkpoint_fni_id = Keyword.get(opts, :reset_to_flow_node_instance_id)
    resettable_state = resettable_state_for(pi_data.state)

    Enum.reduce(surviving_fnis, [], fn fni, accumulator ->
      cond do
        fni.id == checkpoint_fni_id ->
          [{fni.id, "active"} | accumulator]

        non_retryable_fni?(fni) ->
          accumulator

        fni.state == resettable_state ->
          [{fni.id, "active"} | accumulator]

        true ->
          accumulator
      end
    end)
    |> Enum.reverse()
  end

  defp resettable_state_for("fatal"), do: "fatal"
  defp resettable_state_for("aborted"), do: "aborted"
  defp resettable_state_for("error"), do: "error"
  defp resettable_state_for(other), do: other

  defp reset_ancestor_chain(ancestor_chain, adapter) do
    Enum.reduce_while(ancestor_chain, {:ok, []}, fn ancestor, {:ok, accumulator} ->
      case reset_single_ancestor(ancestor, adapter) do
        {:ok, original} ->
          {:cont, {:ok, [original | accumulator]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, resets} -> {:ok, Enum.reverse(resets)}
      error -> error
    end
  end

  defp reset_single_ancestor(ancestor, adapter) do
    with {:ok, reset_spec} <- build_basic_reset_spec(ancestor, adapter),
         {:ok, _reactivation_fnis} <-
           retry_adapter_call(adapter, :execute_retry_reset, [ancestor.id, reset_spec]) do
      {:ok, {ancestor.id, ancestor.state, ancestor.finished_at}}
    end
  end

  defp build_basic_reset_spec(pi_data, adapter) do
    resettable_state = resettable_state_for(pi_data.state)

    case retry_adapter_call(adapter, :list_all_flow_node_instances, [pi_data.id]) do
      {:ok, fnis} ->
        reset_fni_ids =
          fnis
          |> Enum.filter(fn fni ->
            fni.state == resettable_state and
              not non_retryable_fni?(fni)
          end)
          |> Enum.map(&{&1.id, "active"})

        {:ok, %{reset_fni_ids: reset_fni_ids}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reset_descendants(reset_pi_list, adapter) do
    do_reset_descendants(reset_pi_list, adapter, [])
  end

  defp do_reset_descendants([], _adapter, accumulated_resets), do: {:ok, accumulated_resets}

  defp do_reset_descendants([pi_data | rest], adapter, accumulated_resets) do
    case retry_adapter_call(adapter, :list_child_process_instances, [pi_data.id]) do
      {:ok, children} ->
        case reset_and_reconcile_children(pi_data.id, children, adapter, accumulated_resets) do
          {:ok, new_accumulated_resets} ->
            do_reset_descendants(rest, adapter, new_accumulated_resets)

          error ->
            error
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reset_and_reconcile_children(_parent_pi_id, [], _adapter, accumulated_resets) do
    {:ok, accumulated_resets}
  end

  defp reset_and_reconcile_children(parent_pi_id, [child | rest], adapter, accumulated_resets) do
    _reconcile_result = reconcile_parent_fni_child_id(child, adapter)

    case try_reset_child(child.id, child.state, adapter, accumulated_resets) do
      {:ok, new_accumulated} ->
        reset_and_reconcile_children(parent_pi_id, rest, adapter, new_accumulated)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reconcile_parent_fni_child_id(%{triggerer_flow_node_instance_id: nil}, _adapter), do: :ok

  defp reconcile_parent_fni_child_id(child, adapter) do
    retry_adapter_call(adapter, :patch_fni_type_properties, [
      child.triggerer_flow_node_instance_id,
      %{"child_process_instance_id" => child.id}
    ])
  end

  defp try_reset_child(child_pi_id, child_state, adapter, accumulated_resets)
       when child_state in ["fatal", "aborted", "error"] do
    case retry_adapter_call(adapter, :get_process_instance_for_retry, [child_pi_id]) do
      {:ok, child_data} ->
        reset_and_recurse_child(child_data, adapter, accumulated_resets)

      {:error, :not_found} ->
        {:ok, accumulated_resets}
    end
  end

  defp try_reset_child(_child_pi_id, _child_state, _adapter, accumulated_resets) do
    {:ok, accumulated_resets}
  end

  defp reset_and_recurse_child(child_data, adapter, accumulated_resets) do
    case reset_single_descendant(child_data, adapter) do
      {:ok, reset_info} ->
        do_reset_descendants([child_data], adapter, [reset_info | accumulated_resets])

      error ->
        error
    end
  end

  defp reset_single_descendant(child_data, adapter) do
    case build_basic_reset_spec(child_data, adapter) do
      {:ok, reset_spec} ->
        original = {child_data.id, child_data.state, child_data.finished_at}

        case retry_adapter_call(adapter, :execute_retry_reset, [child_data.id, reset_spec]) do
          {:ok, _reactivation_fnis} -> {:ok, original}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_resume_opts(root_pi_data, root_fnis) do
    adapter = Persistence.adapter()

    pending_arrivals =
      case adapter.list_gateway_pending_arrivals(root_pi_data.id) do
        {:ok, arrivals} -> arrivals
        {:error, _reason} -> []
      end

    %{
      resume: true,
      process_instance_id: root_pi_data.id,
      process_version_id: root_pi_data.process_version_id,
      business_key: root_pi_data.business_key,
      parent_process_instance_id: root_pi_data.parent_process_instance_id,
      triggerer_flow_node_instance_id: root_pi_data.triggerer_flow_node_instance_id,
      started_at: root_pi_data.started_at,
      started_by: root_pi_data.started_by,
      started_with_context: root_pi_data.started_with_context,
      fni_data: root_fnis,
      pending_arrivals: pending_arrivals
    }
  end

  defp emit_retry_event(root_pi_data, targeted_pi_data, resolved_version_id, identity, opts, root_fnis) do
    is_version_migration = resolved_version_id != targeted_pi_data.process_version_id

    previous_version = if is_version_migration, do: targeted_pi_data.process_version_id
    new_version = if is_version_migration, do: resolved_version_id

    process_model_id = resolve_process_model_id(resolved_version_id)
    lane_names = Enum.map(root_fnis, & &1.lane_name)
    has_laneless_flow_node = Enum.any?(lane_names, &is_nil/1)
    distinct_lane_names = lane_names |> Enum.reject(&is_nil/1) |> Enum.uniq() |> Enum.sort()

    started_by_id =
      get_in(root_pi_data.started_by, ["id"]) || get_in(root_pi_data.started_by, [:id])

    event = %Event.ProcessInstanceRetried{
      process_instance_id: root_pi_data.id,
      target_process_instance_id: targeted_pi_data.id,
      process_model_id: process_model_id,
      version: resolved_version_id,
      previous_state: String.to_existing_atom(targeted_pi_data.state),
      previous_version: previous_version,
      new_version: new_version,
      reset_to_flow_node_instance_id: Keyword.get(opts, :reset_to_flow_node_instance_id),
      retried_by: identity.id,
      started_by_id: started_by_id,
      has_laneless_flow_node: has_laneless_flow_node,
      lane_names: distinct_lane_names,
      occurred_at: DateTime.utc_now()
    }

    EngineEventBus.publish(event)

    :telemetry.execute(
      [:evil_engine, :process_instance, :retried],
      %{system_time: System.system_time()},
      %{
        process_instance_id: root_pi_data.id,
        target_process_instance_id: targeted_pi_data.id,
        previous_state: targeted_pi_data.state
      }
    )
  end

  defp resolve_process_model_id(process_version_id) do
    case ModelCache.fetch(process_version_id) do
      {:ok, definitions} ->
        case Enum.find(definitions.processes, & &1.is_executable) do
          %{id: process_id} -> process_id
          nil -> process_version_id
        end

      _error ->
        process_version_id
    end
  end

  defp revert_tree_retry(all_resets, adapter) do
    Enum.each(all_resets, fn {process_instance_id, original_state, original_finished_at} ->
      case retry_adapter_call(adapter, :revert_retry, [
             process_instance_id,
             original_state,
             original_finished_at
           ]) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.error(
            "Failed to revert PI #{process_instance_id} during retry rollback: #{inspect(reason)}"
          )
      end
    end)
  end

  defp retry_adapter_call(adapter, function_name, args) do
    PersistenceRetry.with_retry(
      fn -> apply(adapter, function_name, args) end,
      "Retry: #{function_name}",
      max_attempts: 3
    )
  end
end
