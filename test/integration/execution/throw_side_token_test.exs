defmodule BfwEngine.Integration.Execution.ThrowSideTokenTest do
  @moduledoc """
  Throw-side message and signal handlers publish the mapping result and keep
  every unmapped token field downstream (C6). A Send Task stamps its own
  `bfw:correlationRetrievalExpression` onto the published message (C12).
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

  defp pending_messages(message_name) do
    PendingMessage
    |> Ash.read!(domain: BfwEngine.Persistence.Api, authorize?: false)
    |> Enum.filter(&(&1.message_name == message_name))
  end
end
