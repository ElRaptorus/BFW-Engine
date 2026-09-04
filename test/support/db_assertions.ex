defmodule EvilEngine.Test.DbAssertions do
  @moduledoc """
  Helpers for querying and asserting against Ash-persisted
  execution records in integration tests.
  """

  import ExUnit.Assertions

  require Ash.Query

  alias EvilEngine.Persistence.Api, as: Domain
  alias EvilEngine.Persistence.Resources.FlowNodeInstance
  alias EvilEngine.Persistence.Resources.ProcessInstance
  alias EvilEngine.Types.Event

  @sandbox_retry_attempts 6
  @sandbox_retry_delay_ms 25
  @terminal_process_instance_states ~w(finished fatal aborted error compensated escalated cancelled)
  @terminal_fni_states ~w(finished fatal interrupted aborted error)
  @parked_flow_node_types MapSet.new([
                            "user_task",
                            "receive_task",
                            "service_task",
                            "call_activity",
                            "sub_process"
                          ])
  @waiting_catch_event_types MapSet.new(["message", "signal", "timer", "conditional"])

  @doc "Fetch a ProcessInstance row by ID. Raises on not-found."
  def fetch_process_instance!(process_instance_id) do
    with_sandbox_retry(fn ->
      Ash.get!(ProcessInstance, process_instance_id, domain: Domain, authorize?: false)
    end)
  end

  @doc "Fetch a ProcessInstance row by ID. Returns nil if not found."
  def fetch_process_instance(process_instance_id) do
    with_sandbox_retry(fn ->
      case Ash.get(ProcessInstance, process_instance_id, domain: Domain, authorize?: false) do
        {:ok, record} ->
          record

        {:error, error} ->
          if not_found_error?(error) do
            nil
          else
            raise error
          end
      end
    end)
  end

  @doc "List child ProcessInstance IDs for a parent PI."
  def list_child_process_instance_ids(parent_process_instance_id) do
    with_sandbox_retry(fn ->
      ProcessInstance
      |> Ash.Query.filter(parent_process_instance_id == ^parent_process_instance_id)
      |> Ash.read!(domain: Domain, authorize?: false)
      |> Enum.map(& &1.id)
    end)
  end

  @doc """
  Poll until at least one child ProcessInstance exists for the parent.

  Use this after `wait_for_process_instance/2` when the test requires a
  child row. Do **not** use it when an empty list is a valid assertion
  (the child must not have been spawned).
  """
  def await_child_process_instance_ids(parent_process_instance_id, timeout \\ 10_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_child_process_instance_ids(parent_process_instance_id, deadline)
  end

  defp do_await_child_process_instance_ids(parent_process_instance_id, deadline) do
    child_process_instance_ids = list_child_process_instance_ids(parent_process_instance_id)

    cond do
      child_process_instance_ids != [] ->
        child_process_instance_ids

      System.monotonic_time(:millisecond) >= deadline ->
        raise "No child process instances for parent #{parent_process_instance_id} within timeout"

      true ->
        # Do not restore on an empty list (P82): a fresh checkout starts an
        # empty transaction and hides the parent PI row that is already in
        # the original sandbox transaction.
        Process.sleep(50)
        do_await_child_process_instance_ids(parent_process_instance_id, deadline)
    end
  end

  @doc "Fetch all FlowNodeInstance rows for a PI, ordered by started_at."
  def fetch_flow_node_instances(process_instance_id) do
    with_sandbox_retry(fn ->
      FlowNodeInstance
      |> Ash.Query.filter(process_instance_id == ^process_instance_id)
      |> Ash.Query.sort(started_at: :asc)
      |> Ash.read!(domain: Domain, authorize?: false)
    end)
  end

  @doc """
  Retry `function` after restoring shared sandbox ownership.

  Public so other test helpers (`ProcessInteractions`) can wrap raw Ash
  reads that would otherwise crash on a torn shared connection (P45/P82).
  """
  def with_sandbox_retry(function, attempt \\ 1) do
    function.()
  rescue
    error ->
      cond do
        attempt < @sandbox_retry_attempts && sandbox_ownership_error?(error) ->
          restore_sandbox_shared_mode()
          Process.sleep(@sandbox_retry_delay_ms * attempt)
          with_sandbox_retry(function, attempt + 1)

        true ->
          reraise error, __STACKTRACE__
      end
  end

  @doc "True when Repo is the Ecto SQL Sandbox, not `DBConnection.ConnectionPool`."
  @spec sandbox_pool?() :: boolean()
  def sandbox_pool? do
    Keyword.get(EvilEngine.Persistence.Repo.config(), :pool) == Ecto.Adapters.SQL.Sandbox
  end

  @doc """
  Hard-delete all persistence rows.

  Used when load tests run on `DBConnection.ConnectionPool` (no sandbox
  rollback). Safe to call on an empty database.
  """
  @spec truncate_persistence_tables() :: :ok
  def truncate_persistence_tables do
    EvilEngine.Persistence.Repo.query!("""
    TRUNCATE
      flow_node_instances,
      process_instances,
      gateway_pending_arrivals,
      data_objects,
      data_object_writes,
      process_instance_events,
      process_versions,
      processes,
      decision_versions,
      decision_definitions,
      timer_start_schedules,
      pending_messages,
      pending_signals,
      messages,
      signals
    RESTART IDENTITY CASCADE
    """)

    :ok
  end

  @doc """
  Re-assert `{:shared, self()}` on both persistence repos.

  Called after a Process Instance drain and from sandbox-retry so a killed
  FNI that was mid-write cannot leave later assertions in `:manual` mode.
  No-op when Repo is a real connection pool (P89).
  """
  def restore_sandbox_shared_mode do
    if sandbox_pool?() do
      Enum.each(
        [EvilEngine.Persistence.Repo, EvilEngine.Persistence.ReadRepo],
        &restore_repo_shared_mode/1
      )
    else
      :ok
    end
  end

  defp restore_repo_shared_mode(repo) do
    case Ecto.Adapters.SQL.Sandbox.checkout(repo, ownership_timeout: 300_000) do
      :ok ->
        Ecto.Adapters.SQL.Sandbox.mode(repo, {:shared, self()})

      {:already, :owner} ->
        Ecto.Adapters.SQL.Sandbox.mode(repo, {:shared, self()})

      {:already, :allowed} ->
        :ok
    end
  rescue
    _error -> :ok
  end

  defp sandbox_ownership_error?(%DBConnection.OwnershipError{}), do: true

  defp sandbox_ownership_error?(%DBConnection.ConnectionError{}), do: true

  defp sandbox_ownership_error?(%Postgrex.Error{} = error) do
    message = Exception.message(error)

    String.contains?(message, "current transaction is aborted") or
      String.contains?(message, "in_failed_sql_transaction")
  end

  defp sandbox_ownership_error?(%Ash.Error.Unknown{errors: errors}) when is_list(errors) do
    Enum.any?(errors, &sandbox_ownership_error?/1)
  end

  defp sandbox_ownership_error?(%Ash.Error.Unknown.UnknownError{error: inner}) do
    sandbox_ownership_error?(inner)
  end

  defp sandbox_ownership_error?(error) when is_exception(error) do
    message = Exception.message(error)

    String.contains?(message, "OwnershipError") or
      String.contains?(message, "ownership process") or
      String.contains?(message, "cannot find ownership") or
      String.contains?(message, "not the owner") or
      String.contains?(message, "connection is closed")
  end

  defp sandbox_ownership_error?(error) when is_binary(error) do
    String.contains?(error, "OwnershipError") or String.contains?(error, "ownership process")
  end

  defp sandbox_ownership_error?(_error), do: false

  defp not_found_error?(%Ash.Error.Query.NotFound{}), do: true

  defp not_found_error?(%Ash.Error.Invalid{errors: errors}) when is_list(errors) do
    Enum.any?(errors, &not_found_error?/1)
  end

  defp not_found_error?(%Ash.Error.Unknown{errors: errors}) when is_list(errors) do
    Enum.any?(errors, &not_found_error?/1)
  end

  defp not_found_error?(_error), do: false

  @doc """
  Assert a PI row exists with the expected state.

  For any call, also verifies the persisted FNI execution chain
  (tokens, timestamps, terminal/non-terminal consistency, and
  Started → optional StateChanged → Finished events). Pass
  `verify_execution_chain: false` only for assertions that run
  before FNIs exist.
  """
  def assert_pi_state!(process_instance_id, expected_state, opts \\ []) do
    process_instance = fetch_process_instance!(process_instance_id)

    assert process_instance.state == expected_state,
           "Expected PI state '#{expected_state}', got '#{process_instance.state}'"

    if Keyword.get(opts, :verify_execution_chain, true) do
      assert_execution_chain!(process_instance_id, expected_state)
    end

    process_instance
  end

  @doc """
  Assert persisted FNI records and event lifecycle for a PI.

  `input_token` is the incoming token at FNI create (before input
  mapping). `output_token` is the payload after output mapping on a
  successful finish. Boundary FNIs may have nil tokens (created
  already-finished on the error path, or finished with an explicit nil
  payload on the subscription path).
  """
  def assert_execution_chain!(process_instance_id, process_instance_state) do
    flow_node_instances = fetch_flow_node_instances(process_instance_id)

    if process_instance_state in @terminal_process_instance_states do
      assert_all_fnis_terminal!(process_instance_id)
    end

    Enum.each(flow_node_instances, &assert_fni_persisted_record!/1)
    assert_fni_event_lifecycle!(process_instance_id, flow_node_instances)

    flow_node_instances
  end

  @doc """
  Assert that every FNI row for a PI is in a terminal state.

  Non-terminal FNIs on a terminal PI indicate leaked runtime state.
  """
  def assert_all_fnis_terminal!(process_instance_id) do
    flow_node_instances = fetch_flow_node_instances(process_instance_id)

    non_terminal_flow_node_instances =
      Enum.reject(flow_node_instances, &(&1.state in @terminal_fni_states))

    assert non_terminal_flow_node_instances == [],
           "Expected all FNIs on PI #{process_instance_id} to be terminal " <>
             "(#{inspect(@terminal_fni_states)}), but found " <>
             "#{length(non_terminal_flow_node_instances)} non-terminal: " <>
             inspect(Enum.map(non_terminal_flow_node_instances, &{&1.flow_node_id, &1.state}))

    flow_node_instances
  end

  @doc "Assert that all FNI rows for a PI have the given state."
  def assert_all_fnis_state!(process_instance_id, expected_state) do
    flow_node_instances = fetch_flow_node_instances(process_instance_id)

    Enum.each(flow_node_instances, fn flow_node_instance ->
      assert flow_node_instance.state == expected_state,
             "FNI #{flow_node_instance.id} (#{flow_node_instance.flow_node_id}) has state '#{flow_node_instance.state}', expected '#{expected_state}'"
    end)

    flow_node_instances
  end

  @doc "Assert that the number of FNI rows matches."
  def assert_flow_node_instance_count!(process_instance_id, expected_count) do
    flow_node_instances = fetch_flow_node_instances(process_instance_id)

    assert length(flow_node_instances) == expected_count,
           "Expected #{expected_count} FNIs, got #{length(flow_node_instances)}: #{inspect(Enum.map(flow_node_instances, & &1.flow_node_id))}"

    flow_node_instances
  end

  @doc "Find a specific FNI by flow_node_id within a PI."
  def find_fni_by_flow_node_id(process_instance_id, flow_node_id) do
    flow_node_instances = fetch_flow_node_instances(process_instance_id)
    Enum.find(flow_node_instances, &(&1.flow_node_id == flow_node_id))
  end

  @doc """
  Assert that no FNI for the given PI is still in "active" or "waiting" state.

  Call this after any PI reaches a terminal state (fatal, aborted) to verify
  `fatal_all_fnis/1` or `abort_all_fnis/1` properly cleaned up all
  non-terminal FNIs.
  """
  def assert_no_running_fnis!(process_instance_id) do
    flow_node_instances = fetch_flow_node_instances(process_instance_id)

    stale_fnis =
      Enum.filter(flow_node_instances, &(&1.state in ["active", "waiting"]))

    assert stale_fnis == [],
           "Expected no active/waiting FNIs on terminal PI #{process_instance_id}, " <>
             "but found #{length(stale_fnis)}: " <>
             inspect(Enum.map(stale_fnis, &{&1.flow_node_id, &1.state}))
  end

  @doc "Assert no PI row exists for the given ID."
  def assert_no_pi!(process_instance_id) do
    assert fetch_process_instance(process_instance_id) == nil,
           "Expected no PI row for #{process_instance_id}, but one exists"
  end

  defp assert_fni_persisted_record!(flow_node_instance) do
    assert flow_node_instance.started_at != nil,
           "FNI #{flow_node_label(flow_node_instance)} is missing started_at"

    if flow_node_instance.state in @terminal_fni_states do
      assert flow_node_instance.finished_at != nil,
             "FNI #{flow_node_label(flow_node_instance)} is terminal " <>
               "(#{flow_node_instance.state}) but missing finished_at"
    end

    unless boundary_event?(flow_node_instance) do
      assert is_map(flow_node_instance.input_token),
             "FNI #{flow_node_label(flow_node_instance)} is missing persisted input_token " <>
               "(got #{inspect(flow_node_instance.input_token)}). " <>
               "input_token is the incoming payload before input mapping."
    end

    case flow_node_instance.state do
      "finished" ->
        unless boundary_event?(flow_node_instance) do
          assert is_map(flow_node_instance.output_token),
                 "FNI #{flow_node_label(flow_node_instance)} finished without a persisted " <>
                   "output_token (got #{inspect(flow_node_instance.output_token)}). " <>
                   "Ash :update_finished accepts :output_token, not :output_payload (P86)."
        end

      "error" ->
        if flow_node_instance.flow_node_type == "end_event" do
          assert is_map(flow_node_instance.output_token),
                 "Error End FNI #{flow_node_label(flow_node_instance)} must persist output_token"
        end

      _other ->
        :ok
    end
  end

  defp assert_fni_event_lifecycle!(_process_instance_id, flow_node_instances) do
    case Process.get(:evil_engine_test_event_collector) do
      nil ->
        :ok

      collector_pid ->
        events = GenServer.call(collector_pid, :get_events)
        Enum.each(flow_node_instances, &assert_single_fni_event_lifecycle!(&1, events))
    end
  end

  defp assert_single_fni_event_lifecycle!(flow_node_instance, events) do
    started_events = fni_events(events, Event.FlowNodeInstanceStarted, flow_node_instance.id)
    changed_events = fni_events(events, Event.FlowNodeInstanceStateChanged, flow_node_instance.id)
    finished_events = fni_events(events, Event.FlowNodeInstanceFinished, flow_node_instance.id)

    assert started_events != [],
           "FNI #{flow_node_label(flow_node_instance)} has no FlowNodeInstanceStarted event"

    Enum.each(changed_events, fn changed_event ->
      assert {changed_event.old_state, changed_event.new_state} == {:active, :waiting},
             "FNI #{flow_node_label(flow_node_instance)} has unexpected StateChanged " <>
               "#{changed_event.old_state} → #{changed_event.new_state}"
    end)

    case flow_node_instance.state do
      "active" ->
        :ok

      "waiting" ->
        assert changed_events != [],
               "FNI #{flow_node_label(flow_node_instance)} is waiting but has no " <>
                 "FlowNodeInstanceStateChanged (active → waiting)"

      state when state in @terminal_fni_states ->
        assert finished_events != [],
               "FNI #{flow_node_label(flow_node_instance)} is #{state} but has no " <>
                 "FlowNodeInstanceFinished event"

        finished_event = List.last(finished_events)

        assert Atom.to_string(finished_event.terminal_state) == state,
               "FNI #{flow_node_label(flow_node_instance)} DB state is #{state} but " <>
                 "Finished.terminal_state is #{inspect(finished_event.terminal_state)}"

        first_started_at = hd(started_events).occurred_at
        last_finished_at = finished_event.occurred_at

        assert DateTime.compare(first_started_at, last_finished_at) != :gt,
               "FNI #{flow_node_label(flow_node_instance)} Finished occurred before Started"

        if require_waiting_transition?(flow_node_instance) do
          assert changed_events != [],
                 "FNI #{flow_node_label(flow_node_instance)} (#{flow_node_instance.flow_node_type}) " <>
                   "finished without an active → waiting StateChanged event"
        end

      other_state ->
        flunk("FNI #{flow_node_label(flow_node_instance)} has unexpected state #{other_state}")
    end
  end

  defp require_waiting_transition?(flow_node_instance) do
    flow_node_instance.state == "finished" and must_have_parked?(flow_node_instance)
  end

  defp must_have_parked?(flow_node_instance) do
    cond do
      mi_or_loop_shell?(flow_node_instance) ->
        mi_or_loop_shell_that_parked?(flow_node_instance)

      flow_node_instance.flow_node_type == "intermediate_catch_event" ->
        MapSet.member?(@waiting_catch_event_types, flow_node_instance.event_type)

      MapSet.member?(@parked_flow_node_types, flow_node_instance.flow_node_type) ->
        true

      true ->
        false
    end
  end

  defp mi_or_loop_shell?(flow_node_instance) do
    is_nil(flow_node_instance.multi_instance_id) and
      (match?(%{"multi_instance" => _}, flow_node_instance.type_properties) or
         match?(%{"standard_loop" => _}, flow_node_instance.type_properties))
  end

  defp mi_or_loop_shell_that_parked?(flow_node_instance) do
    case flow_node_instance.type_properties do
      %{"multi_instance" => %{"total_iterations" => total}}
      when is_integer(total) and total > 0 ->
        true

      %{"standard_loop" => %{"total_iterations" => total}}
      when is_integer(total) and total > 0 ->
        true

      _other ->
        false
    end
  end

  defp fni_events(events, event_module, flow_node_instance_id) do
    Enum.filter(events, fn
      %{__struct__: ^event_module, flow_node_instance_id: ^flow_node_instance_id} -> true
      _other -> false
    end)
  end

  defp boundary_event?(flow_node_instance),
    do: flow_node_instance.flow_node_type == "boundary_event"

  defp flow_node_label(flow_node_instance) do
    "#{flow_node_instance.id} (#{flow_node_instance.flow_node_id})"
  end
end
