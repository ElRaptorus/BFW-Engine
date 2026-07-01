defmodule Examples.ServiceTaskHandlers.HttpEnrichment.HttpEnrichmentHandlerTest do
  use ExUnit.Case

  alias EvilEngine.BPMN.Model.FlowNode
  alias EvilEngine.BPMN.Model.FlowNodeData.ServiceTask, as: ServiceTaskData
  alias EvilEngine.Execution.HandlerContext
  alias EvilEngine.Types.Token

  alias Examples.ServiceTaskHandlers.HttpEnrichment.HttpEnrichmentFacadeStore
  alias Examples.ServiceTaskHandlers.HttpEnrichment.HttpEnrichmentHandler

  setup do
    previous_stub = Process.get(:examples_http_enrichment_request_stub)

    test_pid = self()

    mock_facade = %{
      service_tasks: %{
        finish_async: fn flow_node_instance_id, result ->
          send(test_pid, {:finish_async, flow_node_instance_id, result})
          :ok
        end,
        fail_async: fn flow_node_instance_id, code, message ->
          send(test_pid, {:fail_async, flow_node_instance_id, code, message})
          :ok
        end
      }
    }

    HttpEnrichmentFacadeStore.put(mock_facade)

    on_exit(fn -> restore_stub(previous_stub) end)
    :ok
  end

  test "merges JSON response into output on success (async)" do
    Process.put(:examples_http_enrichment_request_stub, fn _url ->
      {:ok, ~S({"profileScore":42})}
    end)

    flow_node = %FlowNode{
      id: "Task_enrich",
      type: :service_task,
      type_data: %ServiceTaskData{implementation: "http_enrichment"}
    }

    token = %Token{
      id: "token-1",
      process_instance_id: "process-instance-1",
      payload: %{"enrichment_url" => "https://example.com/profile"}
    }

    handler_context = %HandlerContext{
      flow_node_instance_id: "flow-node-instance-1",
      process_instance_id: "process-instance-1",
      identity: %{"sub" => "user-99"}
    }

    assert {:async, "flow-node-instance-1"} =
             HttpEnrichmentHandler.handle_enter(flow_node, token, handler_context)

    assert_receive {:finish_async, "flow-node-instance-1", output}, 1_000
    assert output["profileScore"] == 42
    assert output["enrichment_source"] == "https://example.com/profile"
    assert output["requested_by"] == "user-99"
  end

  test "returns error synchronously when URL is missing" do
    flow_node = %FlowNode{
      id: "Task_enrich",
      type: :service_task,
      type_data: %ServiceTaskData{implementation: "http_enrichment"}
    }

    token = %Token{
      id: "token-1",
      process_instance_id: "process-instance-1",
      payload: %{"no_url" => true}
    }

    handler_context = %HandlerContext{
      flow_node_instance_id: "flow-node-instance-1",
      process_instance_id: "process-instance-1",
      identity: %{}
    }

    assert {:error, :missing_enrichment_url} =
             HttpEnrichmentHandler.handle_enter(flow_node, token, handler_context)
  end

  test "calls fail_async when HTTP layer fails" do
    Process.put(:examples_http_enrichment_request_stub, fn _url ->
      {:error, {:http_error_status, 500}}
    end)

    flow_node = %FlowNode{
      id: "Task_enrich",
      type: :service_task,
      type_data: %ServiceTaskData{implementation: "http_enrichment"}
    }

    token = %Token{
      id: "token-1",
      process_instance_id: "process-instance-1",
      payload: %{"enrichment_url" => "https://example.com/broken"}
    }

    handler_context = %HandlerContext{
      flow_node_instance_id: "flow-node-instance-1",
      process_instance_id: "process-instance-1",
      identity: %{}
    }

    assert {:async, "flow-node-instance-1"} =
             HttpEnrichmentHandler.handle_enter(flow_node, token, handler_context)

    assert_receive {:fail_async, "flow-node-instance-1", "HTTP_ENRICHMENT_ERROR", _message}, 1_000
  end

  defp restore_stub(nil), do: Process.delete(:examples_http_enrichment_request_stub)
  defp restore_stub(value), do: Process.put(:examples_http_enrichment_request_stub, value)
end
