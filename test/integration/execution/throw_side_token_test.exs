defmodule BfwEngine.Integration.Execution.ThrowSideTokenTest do
  @moduledoc """
  Throw-side message and signal handlers publish the mapping result and keep
  every unmapped token field downstream (C6). A Send Task stamps its own
  `bfw:correlationRetrievalExpression` onto the published message (C12). A
  throw inside an embedded subprocess falls back to the inherited process
  `bfw:correlationKey` (D-10.2).
  """
  use BfwEngine.ExecutionCase, async: false

  alias BfwEngine.Persistence.Resources.PendingMessage

  test "Send Task, message throw, and signal throw merge their mapping over the token" do
    process_instance_id =
      http_deploy_and_start("throw_side_token_merge.bpmn", "ThrowSideTokenMerge", %{
        "payload" => %{"orderId" => "ORD-7", "note" => "fragile"}
      })

    inspect_task = poll_fni_state(process_instance_id, "user_task", "waiting")

    assert inspect_task.input_token == %{
             "orderId" => "ORD-7",
             "note" => "fragile",
             "notice" => "fragile",
             "stamped" => true
           }

    assert [order_message] = pending_messages("order-placed-merge")
    assert order_message.payload == %{"orderId" => "ORD-7"}
    assert order_message.correlation_value == "ORD-7"

    assert [notice_message] = pending_messages("order-notice-merge")
    assert notice_message.payload == %{"notice" => "fragile"}
    assert notice_message.correlation_value == nil
  end

  test "Message End and Signal End merge their mapping over the token they end with" do
    process_instance_id =
      http_deploy_and_start("throw_side_end_token_merge.bpmn", "ThrowSideEndTokenMerge", %{
        "payload" => %{"orderId" => "ORD-8", "note" => "urgent"}
      })

    assert {:ok, _process_instance} =
             await_process_instance_state(process_instance_id, "finished")

    assert find_fni_by_flow_node_id(process_instance_id, "End_Message").output_token == %{
             "orderId" => "ORD-8",
             "note" => "urgent",
             "notice" => "urgent"
           }

    assert find_fni_by_flow_node_id(process_instance_id, "End_Signal").output_token == %{
             "orderId" => "ORD-8",
             "note" => "urgent",
             "stamped" => true
           }

    assert [notice_message] = pending_messages("order-end-notice-merge")
    assert notice_message.payload == %{"notice" => "urgent"}
  end

  test "a message throw inside an embedded subprocess stamps the inherited process correlation key" do
    process_instance_id =
      http_deploy_and_start(
        "subprocess_message_throw_correlation.bpmn",
        "SubprocessMessageThrowCorrelation",
        %{"payload" => %{"orderId" => "SUB-3"}}
      )

    assert {:ok, _process_instance} =
             await_process_instance_state(process_instance_id, "finished")

    assert [shipped_message] = pending_messages("subprocess-throw-shipped")
    assert shipped_message.correlation_value == "SUB-3"
  end

  defp pending_messages(message_name) do
    PendingMessage
    |> Ash.read!(domain: BfwEngine.Persistence.Api, authorize?: false)
    |> Enum.filter(&(&1.message_name == message_name))
  end
end
