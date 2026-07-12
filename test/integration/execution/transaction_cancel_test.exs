defmodule EvilEngine.Integration.Execution.TransactionCancelTest do
  @moduledoc """
  Umbrella-level integration tests for Transaction Subprocess + Cancel Events (TX-1–TX-15).

  Uses real BPMN XML fixtures deployed via the HTTP API. Verifies PI state,
  FNI states, automatic compensation (LIFO), Cancel Boundary routing, hazard
  behaviour, and retry restrictions against a real database.

  Scenarios covered:
  - TX-1:  Happy path — Transaction succeeds, Cancel Boundary NOT fired
  - TX-2:  Basic cancel — Cancel End fires, Cancel Boundary fires, parent continues
  - TX-3:  Cancel with multiple compensable activities — verify LIFO ordering
  - TX-4:  Hazard — uncaught error inside transaction, NO compensation, parent fatals
  - TX-5:  Error boundary inside transaction routes to Cancel End
  - TX-6:  No Cancel Boundary on shell → parent hazards (fatal)
  - TX-7:  Transaction with Call Activity — cancel interrupts child PI
  - TX-8:  Transaction with embedded subprocess — cancel interrupts child PI
  - TX-9:  Parallel branches — one cancels, other interrupted
  - TX-10: Compensation handler fatals during cancel → hazard
  - TX-11: :cancelled PI is not retryable
  - TX-12: Retry checkpoint inside transaction → rejected
  - TX-13: TX → SP → child fatal. Retry child PI directly → 422 retry_inside_transaction_scope
  - TX-14: TX → CA → child fatal. Retry child PI directly → 422 retry_inside_transaction_scope
  - TX-15: TX → SP → CA → grandchild fatal. Retry grandchild → 422, SP child → 422, TX shell → succeeds
  """
  use EvilEngine.ExecutionCase, async: false

  alias EvilEngine.Persistence.Resources.ProcessInstance
  alias EvilEngine.Test.EventCollector
  alias EvilEngine.Types.Event

  require Ash.Query

  @default_timeout 20_000

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp find_child_process_instance_ids(parent_process_instance_id) do
    ProcessInstance
    |> Ash.Query.filter(parent_process_instance_id == ^parent_process_instance_id)
    |> Ash.read!(domain: EvilEngine.Persistence.Api, authorize?: false)
    |> Enum.map(& &1.id)
  end

  # ---------------------------------------------------------------------------
  # TX-1: Happy path — Transaction completes normally; Cancel Boundary NOT fired
  # ---------------------------------------------------------------------------

  describe "TX-1: transaction happy path" do
    test "transaction succeeds, parent finishes normally, cancel boundary not fired" do
      {201, _} = http_deploy("transaction_happy_path.bpmn")

      {201, body} = http_start("transaction_happy_path")
      pi_id = body["processInstanceId"]

      wait_for_process_instance(pi_id, @default_timeout)
      assert_pi_state!(pi_id, "finished")

      [child_pi_id] = find_child_process_instance_ids(pi_id)
      assert_pi_state!(child_pi_id, "finished")

      child_fnis = fetch_flow_node_instances(child_pi_id)

      cancel_end_fni = Enum.find(child_fnis, &(&1.flow_node_id == "Tx_CancelEnd"))
      assert cancel_end_fni == nil,
             "Cancel End FNI must NOT exist — transaction succeeded without cancel"

      parent_fnis = fetch_flow_node_instances(pi_id)
      cancel_boundary_fni = Enum.find(parent_fnis, &(&1.flow_node_id == "Boundary_Cancel"))
      assert cancel_boundary_fni == nil,
             "Cancel Boundary FNI must NOT be created on a successful transaction"

      end_normal_fni = Enum.find(parent_fnis, &(&1.flow_node_id == "End_Normal"))
      assert end_normal_fni != nil
      assert end_normal_fni.state == "finished"
    end
  end

  # ---------------------------------------------------------------------------
  # TX-2: Basic cancel — Cancel End fires, Cancel Boundary fires, parent continues
  # ---------------------------------------------------------------------------

  describe "TX-2: basic cancel" do
    test "cancel end fires, child pi cancelled, cancel boundary fires, parent reaches End_Cancelled",
         %{collector: collector} do
      {201, _} = http_deploy("transaction_cancel_basic.bpmn")

      {201, body} = http_start("transaction_cancel_basic")
      pi_id = body["processInstanceId"]

      wait_for_process_instance(pi_id, @default_timeout)
      assert_pi_state!(pi_id, "finished")

      [child_pi_id] = find_child_process_instance_ids(pi_id)
      assert_pi_state!(child_pi_id, "cancelled")

      child_fnis = fetch_flow_node_instances(child_pi_id)

      cancel_end_fni = Enum.find(child_fnis, &(&1.flow_node_id == "Tx_CancelEnd"))
      assert cancel_end_fni != nil
      assert cancel_end_fni.state == "finished"

      parent_fnis = fetch_flow_node_instances(pi_id)

      end_cancelled_fni = Enum.find(parent_fnis, &(&1.flow_node_id == "End_Cancelled"))
      assert end_cancelled_fni != nil
      assert end_cancelled_fni.state == "finished"

      end_normal_fni = Enum.find(parent_fnis, &(&1.flow_node_id == "End_Normal"))
      assert end_normal_fni == nil,
             "End_Normal must not be reached when Cancel Boundary fires"

      events = EventCollector.get_events(collector)

      transaction_cancelled = Enum.find(events, &match?(%Event.TransactionCancelled{}, &1))
      assert transaction_cancelled != nil, "TransactionCancelled event must be emitted"
      assert transaction_cancelled.process_instance_id == child_pi_id

      pi_cancelled =
        Enum.find(events, fn
          %Event.ProcessInstanceStateChanged{new_state: :cancelled, process_instance_id: ^child_pi_id} -> true
          _ -> false
        end)

      assert pi_cancelled != nil, "ProcessInstanceStateChanged with :cancelled must be emitted"
    end
  end

  # ---------------------------------------------------------------------------
  # TX-3: LIFO compensation ordering
  # ---------------------------------------------------------------------------

  describe "TX-3: LIFO compensation during cancel" do
    test "compensation runs in reverse order (B first, then A)", %{collector: collector} do
      {201, _} = http_deploy("transaction_cancel_with_compensation.bpmn")

      {201, body} = http_start("transaction_cancel_with_compensation")
      pi_id = body["processInstanceId"]

      wait_for_process_instance(pi_id, @default_timeout)
      assert_pi_state!(pi_id, "finished")

      [child_pi_id] = find_child_process_instance_ids(pi_id)
      assert_pi_state!(child_pi_id, "cancelled")

      child_fnis = fetch_flow_node_instances(child_pi_id)

      comp_b_fni = Enum.find(child_fnis, &(&1.flow_node_id == "Tx_CompB"))
      comp_a_fni = Enum.find(child_fnis, &(&1.flow_node_id == "Tx_CompA"))

      assert comp_b_fni != nil, "Compensation handler B must run"
      assert comp_b_fni.state == "finished"
      assert comp_a_fni != nil, "Compensation handler A must run"
      assert comp_a_fni.state == "finished"

      assert DateTime.compare(comp_b_fni.started_at, comp_a_fni.started_at) in [:lt, :eq],
             "Comp B must start before (or equal to) Comp A (LIFO — B was registered after A)"

      events = EventCollector.get_events(collector)

      tx_cancelled = Enum.find(events, &match?(%Event.TransactionCancelled{}, &1))
      assert tx_cancelled != nil
      assert tx_cancelled.compensation_handler_count == 2
    end
  end

  # ---------------------------------------------------------------------------
  # TX-4: Hazard — uncaught error inside transaction, no compensation, parent fatals
  # ---------------------------------------------------------------------------

  describe "TX-4: hazard (uncaught error)" do
    test "transaction fatals without running compensation, parent fatals" do
      {201, _} = http_deploy("transaction_hazard_error.bpmn")

      {201, body} = http_start("transaction_hazard_error")
      pi_id = body["processInstanceId"]

      wait_for_process_instance(pi_id, @default_timeout)
      assert_pi_state!(pi_id, "fatal")

      [child_pi_id] = find_child_process_instance_ids(pi_id)
      assert_pi_state!(child_pi_id, "fatal")

      child_fnis = fetch_flow_node_instances(child_pi_id)

      comp_a_fni = Enum.find(child_fnis, &(&1.flow_node_id == "Tx_CompA"))
      assert comp_a_fni == nil,
             "Compensation handler must NOT run on a hazard (uncaught error)"
    end
  end

  # ---------------------------------------------------------------------------
  # TX-5: Error boundary inside transaction routes to Cancel End
  # ---------------------------------------------------------------------------

  describe "TX-5: error boundary inside transaction → cancel end" do
    test "error caught by inner boundary, compensate throw, cancel end fires, cancel boundary catches" do
      {201, _} = http_deploy("transaction_error_boundary_inside.bpmn")

      {201, body} = http_start("transaction_error_boundary_inside",
        %{"shouldFail" => true})
      pi_id = body["processInstanceId"]

      wait_for_process_instance(pi_id, @default_timeout)
      assert_pi_state!(pi_id, "finished")

      [child_pi_id] = find_child_process_instance_ids(pi_id)
      assert_pi_state!(child_pi_id, "cancelled")

      parent_fnis = fetch_flow_node_instances(pi_id)
      end_cancelled_fni = Enum.find(parent_fnis, &(&1.flow_node_id == "End_Cancelled"))
      assert end_cancelled_fni != nil
      assert end_cancelled_fni.state == "finished"
    end
  end

  # ---------------------------------------------------------------------------
  # TX-6: No Cancel Boundary on shell → parent hazards (fatal)
  # ---------------------------------------------------------------------------

  describe "TX-6: no cancel boundary on shell" do
    test "cancel end fires, no cancel boundary exists, parent fatals (unhandled cancel)" do
      {201, _} = http_deploy("transaction_no_cancel_boundary.bpmn")

      {201, body} = http_start("transaction_no_cancel_boundary")
      pi_id = body["processInstanceId"]

      wait_for_process_instance(pi_id, @default_timeout)
      assert_pi_state!(pi_id, "fatal")

      [child_pi_id] = find_child_process_instance_ids(pi_id)
      assert_pi_state!(child_pi_id, "cancelled")
    end
  end

  # ---------------------------------------------------------------------------
  # TX-7: Transaction with Call Activity — cancel interrupts child PI
  # ---------------------------------------------------------------------------

  describe "TX-7: transaction with call activity" do
    test "cancel end fires, call activity child PI is interrupted, cancel boundary fires" do
      {201, _} = http_deploy("transaction_with_call_activity_child.bpmn")
      {201, _} = http_deploy("transaction_with_call_activity.bpmn")

      {201, body} = http_start("transaction_with_call_activity")
      pi_id = body["processInstanceId"]

      wait_for_process_instance(pi_id, @default_timeout)

      [tx_child_pi_id] = find_child_process_instance_ids(pi_id)

      ca_child_pi_ids = find_child_process_instance_ids(tx_child_pi_id)

      Enum.each(ca_child_pi_ids, fn ca_child_pi_id ->
        wait_for_process_instance(ca_child_pi_id, @default_timeout)
      end)

      assert_pi_state!(pi_id, "finished")
      assert_pi_state!(tx_child_pi_id, "cancelled")

      parent_fnis = fetch_flow_node_instances(pi_id)
      end_cancelled_fni = Enum.find(parent_fnis, &(&1.flow_node_id == "End_Cancelled"))
      assert end_cancelled_fni != nil
      assert end_cancelled_fni.state == "finished"
    end
  end

  # ---------------------------------------------------------------------------
  # TX-8: Transaction with embedded subprocess — cancel interrupts child PI
  # ---------------------------------------------------------------------------

  describe "TX-8: transaction with embedded subprocess" do
    test "cancel end fires, embedded subprocess is interrupted, cancel boundary fires" do
      {201, _} = http_deploy("transaction_with_embedded_subprocess.bpmn")

      {201, body} = http_start("transaction_with_embedded_subprocess")
      pi_id = body["processInstanceId"]

      wait_for_process_instance(pi_id, @default_timeout)

      [tx_child_pi_id] = find_child_process_instance_ids(pi_id)

      sp_child_pi_ids = find_child_process_instance_ids(tx_child_pi_id)

      Enum.each(sp_child_pi_ids, fn sp_child_pi_id ->
        wait_for_process_instance(sp_child_pi_id, @default_timeout)
      end)

      assert_pi_state!(pi_id, "finished")
      assert_pi_state!(tx_child_pi_id, "cancelled")

      tx_child_fnis = fetch_flow_node_instances(tx_child_pi_id)
      sp_fni = Enum.find(tx_child_fnis, &(&1.flow_node_id == "Tx_SP"))
      assert sp_fni != nil

      assert sp_fni.state in ["interrupted", "aborted"],
             "Embedded subprocess shell FNI must be interrupted/aborted by Cancel End"

      parent_fnis = fetch_flow_node_instances(pi_id)
      end_cancelled_fni = Enum.find(parent_fnis, &(&1.flow_node_id == "End_Cancelled"))
      assert end_cancelled_fni != nil
      assert end_cancelled_fni.state == "finished"
    end
  end

  # ---------------------------------------------------------------------------
  # TX-9: Parallel branches — one cancels, other interrupted
  # ---------------------------------------------------------------------------

  describe "TX-9: parallel branches with cancel" do
    test "branch A reaches cancel end, branch B user task is interrupted, compensation runs" do
      {201, _} = http_deploy("transaction_parallel_cancel.bpmn")

      {201, body} = http_start("transaction_parallel_cancel")
      pi_id = body["processInstanceId"]

      wait_for_process_instance(pi_id, @default_timeout)
      assert_pi_state!(pi_id, "finished")

      [child_pi_id] = find_child_process_instance_ids(pi_id)
      assert_pi_state!(child_pi_id, "cancelled")

      child_fnis = fetch_flow_node_instances(child_pi_id)

      user_task_fni = Enum.find(child_fnis, &(&1.flow_node_id == "Tx_UserTask"))
      assert user_task_fni != nil
      assert user_task_fni.state in ["interrupted", "aborted"],
             "User task on parallel branch B must be interrupted by Cancel End"

      comp_a_fni = Enum.find(child_fnis, &(&1.flow_node_id == "Tx_CompA"))
      assert comp_a_fni != nil
      assert comp_a_fni.state == "finished",
             "Compensation handler A must run after cancel"

      parent_fnis = fetch_flow_node_instances(pi_id)
      end_cancelled_fni = Enum.find(parent_fnis, &(&1.flow_node_id == "End_Cancelled"))
      assert end_cancelled_fni != nil
      assert end_cancelled_fni.state == "finished"
    end
  end

  # ---------------------------------------------------------------------------
  # TX-10: Compensation handler fatals during cancel → hazard
  # ---------------------------------------------------------------------------

  describe "TX-10: compensation fails during cancel" do
    test "compensation handler fatals, transaction hazards (fatal), cancel boundary not fired" do
      {201, _} = http_deploy("transaction_cancel_compensation_fails.bpmn")

      {201, body} = http_start("transaction_cancel_compensation_fails")
      pi_id = body["processInstanceId"]

      wait_for_process_instance(pi_id, @default_timeout)
      assert_pi_state!(pi_id, "fatal")

      [child_pi_id] = find_child_process_instance_ids(pi_id)
      child = assert_pi_state!(child_pi_id, "fatal")
      assert child.state == "fatal", "Child PI must be fatal when compensation fails during cancel"

      parent_fnis = fetch_flow_node_instances(pi_id)
      end_cancelled_fni = Enum.find(parent_fnis, &(&1.flow_node_id == "End_Cancelled"))
      assert end_cancelled_fni == nil,
             "End_Cancelled must NOT be reached — compensation failure prevents successful cancel"
    end
  end

  # ---------------------------------------------------------------------------
  # TX-11: :cancelled PI is not retryable
  # ---------------------------------------------------------------------------

  describe "TX-11: cancelled PI is not retryable" do
    test "attempt to retry a :cancelled child PI returns 422 process_instance_not_retriable" do
      {201, _} = http_deploy("transaction_cancel_basic.bpmn")

      {201, body} = http_start("transaction_cancel_basic")
      pi_id = body["processInstanceId"]

      wait_for_process_instance(pi_id, @default_timeout)
      assert_pi_state!(pi_id, "finished")

      [child_pi_id] = find_child_process_instance_ids(pi_id)
      assert_pi_state!(child_pi_id, "cancelled")

      {422, error_body} = http_retry_process_instance(child_pi_id)
      assert error_body["error"] == "process_instance_not_retriable",
             "Expected process_instance_not_retriable, got: #{inspect(error_body)}"
    end
  end

  # ---------------------------------------------------------------------------
  # TX-12: Retry of direct transaction child PI is blocked
  # ---------------------------------------------------------------------------
  # When a transaction hazards (fatal), the transaction child PI is in "fatal"
  # state. Even though "fatal" is normally retryable, the engine blocks retry
  # for any PI spawned directly by a transaction subprocess shell FNI.

  describe "TX-12: retry of direct transaction child PI is blocked" do
    test "transaction hazard: child PI fatal, retry child PI → 422 retry_inside_transaction_scope" do
      {201, _} = http_deploy("transaction_hazard_error.bpmn")

      {201, body} = http_start("transaction_hazard_error")
      pi_id = body["processInstanceId"]

      wait_for_process_instance(pi_id, @default_timeout)
      assert_pi_state!(pi_id, "fatal")

      [child_pi_id] = find_child_process_instance_ids(pi_id)
      assert_pi_state!(child_pi_id, "fatal")

      {422, error_body} = http_retry_process_instance(child_pi_id)

      assert error_body["error"] == "retry_inside_transaction_scope",
             "Expected retry_inside_transaction_scope when retrying the direct transaction child PI. Got: #{inspect(error_body)}"
    end
  end

  # ---------------------------------------------------------------------------
  # TX-13: TX-RETRY-NESTED-SP — retry of nested SP child PI blocked
  # ---------------------------------------------------------------------------

  describe "TX-13: retry of nested SP child is blocked" do
    test "transaction → SP → SP child fatals. Retry SP child → 422 retry_inside_transaction_scope" do
      {201, _} = http_deploy("transaction_retry_nested_sp.bpmn")

      {201, body} = http_start("transaction_retry_nested_sp")
      pi_id = body["processInstanceId"]

      wait_for_process_instance(pi_id, @default_timeout)
      assert_pi_state!(pi_id, "fatal")

      [tx_child_pi_id] = find_child_process_instance_ids(pi_id)
      assert_pi_state!(tx_child_pi_id, "fatal")

      [sp_child_pi_id] = find_child_process_instance_ids(tx_child_pi_id)
      assert_pi_state!(sp_child_pi_id, "fatal")

      {422, error_body} = http_retry_process_instance(sp_child_pi_id)

      assert error_body["error"] == "retry_inside_transaction_scope",
             "Expected retry_inside_transaction_scope when retrying PI below a transaction. Got: #{inspect(error_body)}"
    end
  end

  # ---------------------------------------------------------------------------
  # TX-14: TX-RETRY-NESTED-CA — retry of nested CA child PI blocked
  # ---------------------------------------------------------------------------

  describe "TX-14: retry of nested CA child is blocked" do
    test "transaction → CA → CA child fatals. Retry CA child → 422 retry_inside_transaction_scope" do
      {201, _} = http_deploy("transaction_retry_nested_ca_child.bpmn")
      {201, _} = http_deploy("transaction_retry_nested_ca.bpmn")

      {201, body} = http_start("transaction_retry_nested_ca")
      pi_id = body["processInstanceId"]

      wait_for_process_instance(pi_id, @default_timeout)
      assert_pi_state!(pi_id, "fatal")

      [tx_child_pi_id] = find_child_process_instance_ids(pi_id)
      assert_pi_state!(tx_child_pi_id, "fatal")

      [ca_child_pi_id] = find_child_process_instance_ids(tx_child_pi_id)
      assert_pi_state!(ca_child_pi_id, "fatal")

      {422, error_body} = http_retry_process_instance(ca_child_pi_id)

      assert error_body["error"] == "retry_inside_transaction_scope",
             "Expected retry_inside_transaction_scope when retrying PI below a transaction. Got: #{inspect(error_body)}"
    end
  end

  # ---------------------------------------------------------------------------
  # TX-15: TX-RETRY-NESTED-DEEP — retry blocked at all levels below transaction
  # ---------------------------------------------------------------------------

  describe "TX-15: retry blocked at all levels below transaction" do
    test "TX → SP → CA → grandchild fatals: retry grandchild, SP child both rejected; TX shell retry succeeds" do
      {201, _} = http_deploy("transaction_retry_nested_deep_grandchild.bpmn")
      {201, _} = http_deploy("transaction_retry_nested_deep.bpmn")

      {201, body} = http_start("transaction_retry_nested_deep")
      pi_id = body["processInstanceId"]

      wait_for_process_instance(pi_id, @default_timeout)
      assert_pi_state!(pi_id, "fatal")

      [tx_child_pi_id] = find_child_process_instance_ids(pi_id)
      assert_pi_state!(tx_child_pi_id, "fatal")

      [sp_child_pi_id] = find_child_process_instance_ids(tx_child_pi_id)
      assert_pi_state!(sp_child_pi_id, "fatal")

      [ca_child_pi_id] = find_child_process_instance_ids(sp_child_pi_id)
      assert_pi_state!(ca_child_pi_id, "fatal")

      {422, grandchild_error} = http_retry_process_instance(ca_child_pi_id)

      assert grandchild_error["error"] == "retry_inside_transaction_scope",
             "Grandchild (CA child) retry must be blocked. Got: #{inspect(grandchild_error)}"

      {422, sp_error} = http_retry_process_instance(sp_child_pi_id)

      assert sp_error["error"] == "retry_inside_transaction_scope",
             "SP child retry must be blocked. Got: #{inspect(sp_error)}"

      {204, nil} = http_retry_process_instance(pi_id)

      assert {:ok, _pid} = poll_pi_alive(pi_id, 5_000)
      wait_for_process_instance(pi_id, @default_timeout)
      assert_pi_state!(pi_id, "fatal")
    end
  end
end
