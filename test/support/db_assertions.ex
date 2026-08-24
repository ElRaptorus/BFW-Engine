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

  @sandbox_retry_attempts 8
  @sandbox_retry_delay_ms 50

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
          if sandbox_ownership_error?(error) do
            raise error
          else
            nil
          end
      end
    end)
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

  # Killing an FNI mid-write on the shared sandbox connection (see
  # common-pitfalls.md P45) reverts the checkout to :manual. Re-assert
  # {:shared, test_pid} and retry instead of treating that as a product bug.
  defp with_sandbox_retry(function, attempt \\ 1) do
    function.()
  rescue
    error ->
      if attempt < @sandbox_retry_attempts && sandbox_ownership_error?(error) do
        restore_sandbox_shared_mode()
        Process.sleep(@sandbox_retry_delay_ms * attempt)
        with_sandbox_retry(function, attempt + 1)
      else
        reraise error, __STACKTRACE__
      end
  end

  @doc """
  Re-assert `{:shared, self()}` on both persistence repos.

  Called after a Process Instance drain and from sandbox-retry so a killed
  FNI that was mid-write cannot leave later assertions in `:manual` mode.
  """
  def restore_sandbox_shared_mode do
    Enum.each(
      [EvilEngine.Persistence.Repo, EvilEngine.Persistence.ReadRepo],
      &restore_repo_shared_mode/1
    )
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
      String.contains?(message, "cannot find ownership")
  end

  defp sandbox_ownership_error?(error) when is_binary(error) do
    String.contains?(error, "OwnershipError") or String.contains?(error, "ownership process")
  end

  defp sandbox_ownership_error?(_error), do: false

  @doc "Assert a PI row exists with the expected state."
  def assert_pi_state!(process_instance_id, expected_state) do
    process_instance = fetch_process_instance!(process_instance_id)
    assert process_instance.state == expected_state, "Expected PI state '#{expected_state}', got '#{process_instance.state}'"
    process_instance
  end

  @terminal_fni_states ["finished", "fatal", "interrupted", "aborted", "error"]

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
             inspect(
               Enum.map(non_terminal_flow_node_instances, &{&1.flow_node_id, &1.state})
             )

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
end
