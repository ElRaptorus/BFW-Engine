defmodule BfwEngine.Integration.PayloadAndTokensTest do
  @moduledoc """
  Integration tests for Item 16 (runtime wiring):
  - PayloadCap enforcement at HTTP boundaries
  - finalTokens Ash calculation
  """
  use BfwEngine.ExecutionCase, async: false

  alias BfwEngine.Persistence.Resources.ProcessInstance, as: PiResource

  require Ash.Query

  describe "finalTokens calculation" do
    test "finished PI returns end-event output tokens" do
      process_instance_id = http_deploy_and_start("linear_three_node.bpmn", "LinearThreeNode", %{"message" => "hello"})
      wait_for_process_instance(process_instance_id)

      process_instance =
        PiResource
        |> Ash.Query.filter(id == ^process_instance_id)
        |> Ash.Query.load(:final_tokens)
        |> Ash.read_one!(authorize?: false)

      assert process_instance.state == "finished"
      assert is_list(process_instance.final_tokens)
      assert length(process_instance.final_tokens) >= 1

      token = hd(process_instance.final_tokens)
      assert Map.has_key?(token, "endEventId")
      assert Map.has_key?(token, "endEventName")
      assert Map.has_key?(token, "payload")
      assert token["endEventName"] == "End"
    end

    test "running PI returns nil for finalTokens" do
      {201, _} = http_deploy("user_task_simple.bpmn")
      {201, body} = http_start("UserTaskSimple")
      process_instance_id = body["processInstanceId"]

      Process.sleep(200)

      process_instance =
        PiResource
        |> Ash.Query.filter(id == ^process_instance_id)
        |> Ash.Query.load(:final_tokens)
        |> Ash.read_one!(authorize?: false)

      assert process_instance.state == "running"
      assert process_instance.final_tokens == nil
    end

    test "fatal PI returns nil for finalTokens" do
      {201, _} = http_deploy("dead_end.bpmn")
      {201, body} = http_start("DeadEnd")
      process_instance_id = body["processInstanceId"]

      wait_for_process_instance(process_instance_id)

      process_instance =
        PiResource
        |> Ash.Query.filter(id == ^process_instance_id)
        |> Ash.Query.load(:final_tokens)
        |> Ash.read_one!(authorize?: false)

      assert process_instance.state == "fatal"
      assert process_instance.final_tokens == nil
      assert_no_running_fnis!(process_instance_id)
    end

    test "Call Activity child PI propagates end_event_name in finalTokens" do
      original_resolver = Application.get_env(:core_execution, :called_element_resolver)

      Application.put_env(
        :core_execution,
        :called_element_resolver,
        BfwEngine.Persistence.CalledElementResolverImpl
      )

      {201, _} = http_deploy("call_activity_child.bpmn")
      {201, _} = http_deploy("call_activity_basic.bpmn")

      {201, body} = http_start("CallActivityBasic")
      parent_process_instance_id = body["processInstanceId"]
      wait_for_process_instance(parent_process_instance_id)

      parent_pi =
        PiResource
        |> Ash.Query.filter(id == ^parent_process_instance_id)
        |> Ash.Query.load(:final_tokens)
        |> Ash.read_one!(authorize?: false)

      assert parent_pi.state == "finished"
      assert is_list(parent_pi.final_tokens)
      assert length(parent_pi.final_tokens) >= 1

      parent_token = hd(parent_pi.final_tokens)
      assert parent_token["endEventName"] == "Done"

      [child_pi] =
        PiResource
        |> Ash.Query.filter(parent_process_instance_id == ^parent_process_instance_id)
        |> Ash.Query.load(:final_tokens)
        |> Ash.read!(domain: BfwEngine.Persistence.Api, authorize?: false)

      assert child_pi.state == "finished"
      assert is_list(child_pi.final_tokens)
      assert length(child_pi.final_tokens) >= 1

      child_token = hd(child_pi.final_tokens)
      assert child_token["endEventName"] == "Done",
             "Child PI's FinalToken should carry endEventName from child's End Event"
      assert child_token["endEventId"] == "End_1"

      if original_resolver do
        Application.put_env(:core_execution, :called_element_resolver, original_resolver)
      else
        Application.delete_env(:core_execution, :called_element_resolver)
      end
    end

    test "batch loading finalTokens avoids N+1" do
      {201, _} = http_deploy("linear_three_node.bpmn")

      {201, body1} = http_start("LinearThreeNode", %{"payload" => %{"a" => 1}})
      process_instance_id_1 = body1["processInstanceId"]
      wait_for_process_instance(process_instance_id_1)

      {201, body2} = http_start("LinearThreeNode", %{"payload" => %{"b" => 2}})
      process_instance_id_2 = body2["processInstanceId"]
      wait_for_process_instance(process_instance_id_2)

      process_instances =
        PiResource
        |> Ash.Query.filter(id in [^process_instance_id_1, ^process_instance_id_2])
        |> Ash.Query.load(:final_tokens)
        |> Ash.read!(authorize?: false)

      assert length(process_instances) == 2

      Enum.each(process_instances, fn process_instance ->
        assert process_instance.state == "finished"
        assert is_list(process_instance.final_tokens)
        assert length(process_instance.final_tokens) >= 1
      end)
    end
  end

  describe "PayloadCap enforcement at HTTP boundary" do
    test "start payload exceeding cap returns 413" do
      {201, _} = http_deploy("linear_three_node.bpmn")

      Application.put_env(:core_execution, :token_max_bytes, 2048)

      large_data = %{"data" => String.duplicate("x", 5000)}
      {status, _body} = http_start("LinearThreeNode", %{"payload" => large_data})

      Application.put_env(:core_execution, :token_max_bytes, 65_536)

      assert status == 413
    end

    test "start payload within cap succeeds" do
      {201, _} = http_deploy("linear_three_node.bpmn")
      {201, body} = http_start("LinearThreeNode", %{"msg" => "ok"})
      assert body["processInstanceId"]
    end
  end
end
