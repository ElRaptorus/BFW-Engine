defmodule BfwEngine.Integration.Execution.TimerFeelTemporalValueTest do
  @moduledoc "Regression: timer FEEL expressions that yield a FEEL duration or date-time value fire (D1)."
  use BfwEngine.ExecutionCase, async: false

  @fixture "timer_catch_feel_temporal_value.bpmn"

  describe "D1: FEEL temporal values in timer definitions" do
    @tag skip: "Fixed in Batch 4 (D1)"
    test "timeDuration yielding a FEEL duration fires" do
      process_instance_id = http_deploy_and_start(@fixture, "TimerCatchFeelDuration")

      assert_timer_fired(process_instance_id, "Duration_Timer")
    end

    @tag skip: "Fixed in Batch 4 (D1)"
    test "timeDate yielding a FEEL date and time fires" do
      fire_at =
        DateTime.utc_now()
        |> DateTime.add(1, :second)
        |> DateTime.truncate(:second)
        |> DateTime.to_iso8601()

      process_instance_id =
        http_deploy_and_start(@fixture, "TimerCatchFeelDateTime", %{
          "payload" => %{"fireAt" => fire_at}
        })

      assert_timer_fired(process_instance_id, "DateTime_Timer")
    end
  end

  defp assert_timer_fired(process_instance_id, timer_flow_node_id) do
    finish_result = await_process_instance_state(process_instance_id, "finished")
    timer = find_fni_by_flow_node_id(process_instance_id, timer_flow_node_id)

    assert timer.state == "finished",
           "timer #{timer_flow_node_id} ended #{timer.state}: #{inspect(timer.error_info)}"

    assert {:ok, _process_instance} = finish_result
  end
end
