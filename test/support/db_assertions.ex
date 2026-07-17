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

  @sandbox_retry_attempts 3
  @sandbox_retry_delay_ms 50

  @doc "Fetch a ProcessInstance row by ID. Raises on not-found."
  def fetch_process_instance!(process_instance_id) do
    with_sandbox_retry(fn ->
      Ash.get!(ProcessInstance, process_instance_id, domain: Domain, authorize?: false)
    end)
  end

  @doc "Fetch a ProcessInstance row by ID. Returns nil if not found."
  def fetch_process_instance(process_instance_id) do
    case Ash.get(ProcessInstance, process_instance_id, domain: Domain, authorize?: false) do
      {:ok, record} -> record
      {:error, _} -> nil
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

  defp with_sandbox_retry(function, attempt \\ 1) do
    function.()
  rescue
    error in [Ash.Error.Unknown, DBConnection.OwnershipError] ->
      if attempt < @sandbox_retry_attempts && sandbox_ownership_error?(error) do
        Process.sleep(@sandbox_retry_delay_ms * attempt)
        with_sandbox_retry(function, attempt + 1)
      else
        reraise error, __STACKTRACE__
      end
  end

  defp sandbox_ownership_error?(%DBConnection.OwnershipError{}), do: true

  defp sandbox_ownership_error?(%Ash.Error.Unknown{errors: errors}) do
    Enum.any?(errors, fn
      %Ash.Error.Unknown.UnknownError{error: %DBConnection.OwnershipError{}} -> true
      _ -> false
    end)
  end

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
