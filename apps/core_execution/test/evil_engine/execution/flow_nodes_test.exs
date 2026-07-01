defmodule EvilEngine.Execution.FlowNodesTest do
  use ExUnit.Case, async: true

  alias EvilEngine.BPMN.Model.FlowNode
  alias EvilEngine.BPMN.Model.FlowNodeData
  alias EvilEngine.BPMN.Model.Process, as: BpmnProcess
  alias EvilEngine.BPMN.Model.SequenceFlow
  alias EvilEngine.Execution.FlowNodeResult
  alias EvilEngine.Execution.FlowNodes
  alias EvilEngine.Execution.HandlerContext
  alias EvilEngine.Expressions.Context, as: FeelContext
  alias EvilEngine.Types.Token

  defp make_token(payload \\ %{"key" => "value"}) do
    %Token{
      id: "token-1",
      process_instance_id: "pi-1",
      payload: payload,
      created_at: DateTime.utc_now()
    }
  end

  defp make_context(flow_node, opts \\ []) do
    target_id = Keyword.get(opts, :target_id, "next-node")

    target_node = %FlowNode{
      id: target_id,
      type: :task,
      type_data: %FlowNodeData.Task{}
    }

    sequence_flow = %SequenceFlow{
      id: "sf-#{flow_node.id}-#{target_id}",
      source_ref: flow_node.id,
      target_ref: target_id
    }

    flow_node_with_outgoing = %{flow_node | outgoing: [sequence_flow.id]}
    extra_nodes = Keyword.get(opts, :extra_nodes, [])

    process_model = %BpmnProcess{
      id: "proc-1",
      flow_nodes: [flow_node_with_outgoing, target_node | extra_nodes],
      sequence_flows: Keyword.get(opts, :sequence_flows, [sequence_flow])
    }

    {flow_node_with_outgoing,
     %HandlerContext{
       flow_node_instance_id: "fni-1",
       process_instance_id: "pi-1",
       process_model: process_model,
       flow_node_this: FeelContext.flow_node_this(flow_node)
     }}
  end

  defp make_complete_context(flow_node, target_id \\ "end1") do
    target_node = %FlowNode{id: target_id, type: :task, type_data: %FlowNodeData.Task{}}
    sequence_flow = %SequenceFlow{id: "sf-#{flow_node.id}-#{target_id}", source_ref: flow_node.id, target_ref: target_id}
    flow_node_with_outgoing = %{flow_node | outgoing: [sequence_flow.id]}

    process_model = %BpmnProcess{
      id: "proc-1",
      flow_nodes: [flow_node_with_outgoing, target_node],
      sequence_flows: [sequence_flow]
    }

    {flow_node_with_outgoing,
     %HandlerContext{
       flow_node_instance_id: "fni-1",
       process_instance_id: "pi-1",
       process_model: process_model
     }}
  end

  defp make_end_context(flow_node) do
    process_model = %BpmnProcess{
      id: "proc-1",
      flow_nodes: [flow_node],
      sequence_flows: []
    }

    %HandlerContext{
      flow_node_instance_id: "fni-1",
      process_instance_id: "pi-1",
      process_model: process_model,
      flow_node_this: FeelContext.flow_node_this(flow_node)
    }
  end

  describe "StartEvent" do
    test "passes through token payload unchanged and resolves next_flow_node_ids" do
      base_node = %FlowNode{
        id: "start1",
        type: :start_event,
        type_data: %FlowNodeData.StartEvent{}
      }

      {node, context} = make_context(base_node)
      token = make_token(%{"order" => "123"})

      assert {:ok, %FlowNodeResult{} = result} =
               FlowNodes.StartEvent.handle_enter(node, token, context)

      assert result.output_payload == %{"order" => "123"}
      assert result.next_flow_node_ids == ["next-node"]
    end
  end

  describe "EndEvent" do
    test "passes through payload and stores end event metadata in type_properties" do
      node = %FlowNode{
        id: "end1",
        name: "Order Complete",
        type: :end_event,
        type_data: %FlowNodeData.EndEvent{}
      }

      token = make_token(%{"result" => true})
      context = make_end_context(node)

      assert {:ok, %FlowNodeResult{} = result} =
               FlowNodes.EndEvent.handle_enter(node, token, context)

      assert result.output_payload == %{"result" => true}
      assert result.next_flow_node_ids == []
      assert result.type_properties.end_event_id == "end1"
      assert result.type_properties.end_event_name == "Order Complete"
    end

    test "handles unnamed end events" do
      node = %FlowNode{
        id: "end2",
        name: nil,
        type: :end_event,
        type_data: %FlowNodeData.EndEvent{}
      }

      token = make_token()
      context = make_end_context(node)

      assert {:ok, %FlowNodeResult{} = result} =
               FlowNodes.EndEvent.handle_enter(node, token, context)

      assert result.type_properties.end_event_name == nil
      assert result.next_flow_node_ids == []
    end
  end

  describe "Task (untyped)" do
    test "passes through token payload unchanged and resolves next_flow_node_ids" do
      base_node = %FlowNode{id: "task1", type: :task, type_data: %FlowNodeData.Task{}}
      {node, context} = make_context(base_node)
      token = make_token()

      assert {:ok, %FlowNodeResult{} = result} = FlowNodes.Task.handle_enter(node, token, context)
      assert result.output_payload == token.payload
      assert result.next_flow_node_ids == ["next-node"]
    end
  end

  describe "IntermediateEvent (untyped)" do
    test "passes through token payload unchanged and resolves next_flow_node_ids" do
      base_node = %FlowNode{
        id: "ie1",
        type: :intermediate_catch_event,
        type_data: %FlowNodeData.IntermediateCatchEvent{}
      }

      {node, context} = make_context(base_node)
      token = make_token()

      assert {:ok, %FlowNodeResult{} = result} =
               FlowNodes.IntermediateEvent.handle_enter(node, token, context)

      assert result.output_payload == token.payload
      assert result.next_flow_node_ids == ["next-node"]
    end
  end

  describe "ManualTask" do
    test "without require_confirmation: passes through and resolves next_flow_node_ids" do
      base_node = %FlowNode{
        id: "mt1",
        type: :manual_task,
        type_data: %FlowNodeData.ManualTask{require_confirmation: false}
      }

      {node, context} = make_context(base_node)
      token = make_token()

      assert {:ok, %FlowNodeResult{} = result} =
               FlowNodes.ManualTask.handle_enter(node, token, context)

      assert result.output_payload == token.payload
      assert result.next_flow_node_ids == ["next-node"]
    end

    test "with require_confirmation: enters waiting with pre-resolved next_flow_node_ids" do
      base_node = %FlowNode{
        id: "mt2",
        type: :manual_task,
        type_data: %FlowNodeData.ManualTask{require_confirmation: true}
      }

      {node, context} = make_context(base_node)
      token = make_token()

      assert {:wait, %FlowNodeResult{} = result} =
               FlowNodes.ManualTask.handle_enter(node, token, context)

      assert result.output_payload == token.payload
      assert result.type_properties.require_confirmation == true
      assert result.next_flow_node_ids == ["next-node"]
    end
  end

  describe "UserTask" do
    test "always enters waiting with type_properties and pre-resolved next_flow_node_ids" do
      base_node = %FlowNode{
        id: "ut1",
        type: :user_task,
        type_data: %FlowNodeData.UserTask{
          form_schema: %{"fields" => [%{"name" => "approved", "type" => "boolean"}]},
          assignees_expression: "identity.groups",
          result_contract: %{"type" => "object"},
          due_date: "2025-12-01T10:00:00Z",
          priority: 5
        }
      }

      {node, context} = make_context(base_node)
      token = make_token()

      assert {:wait, %FlowNodeResult{} = result} =
               FlowNodes.UserTask.handle_enter(node, token, context)

      assert result.output_payload == token.payload
      assert result.next_flow_node_ids == ["next-node"]
      assert result.type_properties.form_schema == node.type_data.form_schema
      assert result.type_properties.result_contract == %{"type" => "object"}
      assert result.type_properties.due_date == "2025-12-01T10:00:00Z"
      assert result.type_properties.priority == 5
    end

    test "assignees expression evaluates FEEL and returns list" do
      base_node = %FlowNode{
        id: "ut-assignees",
        type: :user_task,
        type_data: %FlowNodeData.UserTask{
          assignees_expression: "identity.groups"
        }
      }

      {node, base_context} = make_context(base_node)

      context = %{
        base_context
        | identity: %{id: "user-1", groups: ["admin", "clerk"], roles: []}
      }

      token = make_token()

      assert {:wait, %FlowNodeResult{} = result} =
               FlowNodes.UserTask.handle_enter(node, token, context)

      assert result.type_properties.assignees == ["admin", "clerk"]
    end

    test "assignees expression wraps single string in list" do
      base_node = %FlowNode{
        id: "ut-assignees-str",
        type: :user_task,
        type_data: %FlowNodeData.UserTask{
          assignees_expression: ~s("single-assignee")
        }
      }

      {node, context} = make_context(base_node)
      token = make_token()

      assert {:wait, %FlowNodeResult{} = result} =
               FlowNodes.UserTask.handle_enter(node, token, context)

      assert result.type_properties.assignees == ["single-assignee"]
    end

    test "nil assignees expression returns empty list" do
      base_node = %FlowNode{
        id: "ut-nil-assignees",
        type: :user_task,
        type_data: %FlowNodeData.UserTask{assignees_expression: nil}
      }

      {node, context} = make_context(base_node)
      token = make_token()

      assert {:wait, %FlowNodeResult{} = result} =
               FlowNodes.UserTask.handle_enter(node, token, context)

      assert result.type_properties.assignees == []
    end

    test "failing assignees expression degrades gracefully to empty list" do
      base_node = %FlowNode{
        id: "ut-bad-assignees",
        type: :user_task,
        type_data: %FlowNodeData.UserTask{
          assignees_expression: "nonexistent.path.deeply.nested"
        }
      }

      {node, context} = make_context(base_node)
      token = make_token()

      assert {:wait, %FlowNodeResult{} = result} =
               FlowNodes.UserTask.handle_enter(node, token, context)

      assert result.type_properties.assignees == []
    end

    test "finish with valid result returns {:ok, result}" do
      base_node = %FlowNode{
        id: "ut1",
        type: :user_task,
        type_data: %FlowNodeData.UserTask{result_contract: nil}
      }

      {node, context} = make_complete_context(base_node)
      entry = %{next_flow_node_ids: ["end1"]}
      user_result = %{"approved" => true}

      assert {:ok, %FlowNodeResult{output_payload: payload}} =
               FlowNodes.UserTask.handle_complete(node, entry, user_result, context)

      assert payload == %{"approved" => true}
    end

    test "finish with no contract accepts any result" do
      base_node = %FlowNode{
        id: "ut1",
        type: :user_task,
        type_data: %FlowNodeData.UserTask{result_contract: nil}
      }

      {node, context} = make_complete_context(base_node)
      entry = %{next_flow_node_ids: ["end1"]}

      assert {:ok, _result} =
               FlowNodes.UserTask.handle_complete(node, entry, %{"anything" => "goes"}, context)
    end

    test "finish with valid contract and matching result succeeds" do
      contract = %{
        "type" => "object",
        "required" => ["approved"],
        "properties" => %{
          "approved" => %{"type" => "boolean"}
        }
      }

      base_node = %FlowNode{
        id: "ut1",
        type: :user_task,
        type_data: %FlowNodeData.UserTask{result_contract: contract}
      }

      {node, context} = make_complete_context(base_node)
      entry = %{next_flow_node_ids: ["end1"]}

      assert {:ok, _result} =
               FlowNodes.UserTask.handle_complete(node, entry, %{"approved" => true}, context)
    end

    test "finish with contract violation returns error" do
      contract = %{
        "type" => "object",
        "required" => ["approved"],
        "properties" => %{
          "approved" => %{"type" => "boolean"}
        }
      }

      node = %FlowNode{
        id: "ut1",
        type: :user_task,
        type_data: %FlowNodeData.UserTask{result_contract: contract}
      }

      entry = %{next_flow_node_ids: ["end1"]}
      context = %HandlerContext{flow_node_instance_id: "fni-1", process_instance_id: "pi-1"}

      assert {:error, {:contract_violation, _violations}} =
               FlowNodes.UserTask.handle_complete(node, entry, %{"wrong" => "data"}, context)
    end
  end

  describe "MappingHelper" do
    alias EvilEngine.BPMN.Model.Mapping
    alias EvilEngine.Execution.MappingHelper

    defp mapping_context do
      %HandlerContext{
        flow_node_instance_id: "fni-1",
        process_instance_id: "pi-1",
        data_objects: %{},
        process: %{},
        process_instance: %{},
        identity: %{}
      }
    end

    test "apply_in_mappings with empty list returns payload unchanged" do
      assert {:ok, %{"key" => "value"}} =
               MappingHelper.apply_in_mappings([], %{"key" => "value"}, mapping_context())
    end

    test "apply_in_mappings with nil payload returns empty map" do
      assert {:ok, %{}} = MappingHelper.apply_in_mappings([], nil, mapping_context())
    end

    test "apply_in_mappings with valid FEEL mapping transforms payload" do
      mappings = [%Mapping{source: "token.order_id", target: "id"}]
      ctx = mapping_context()

      assert {:ok, %{"id" => "ORD-123"}} =
               MappingHelper.apply_in_mappings(mappings, %{"order_id" => "ORD-123"}, ctx)
    end

    test "apply_in_mappings with corrupt FEEL returns error" do
      mappings = [%Mapping{source: "for x in [1] return if x then", target: "id"}]
      ctx = mapping_context()

      assert {:error, {:feel_eval_failed, "for x in [1] return if x then", _reason}} =
               MappingHelper.apply_in_mappings(mappings, %{}, ctx)
    end

    test "apply_out_mappings with valid FEEL mapping transforms payload" do
      mappings = [%Mapping{source: "token.result", target: "output"}]
      ctx = mapping_context()

      assert {:ok, %{"output" => 42}} =
               MappingHelper.apply_out_mappings(mappings, %{"result" => 42}, ctx)
    end

    test "apply_out_mappings with corrupt FEEL returns error" do
      mappings = [%Mapping{source: "for x in [1] return if x then", target: "out"}]
      ctx = mapping_context()

      assert {:error, {:feel_eval_failed, _, _}} =
               MappingHelper.apply_out_mappings(mappings, %{}, ctx)
    end

    test "validate_contract with nil contract always passes" do
      assert :ok = MappingHelper.validate_contract(nil, %{"anything" => true})
    end

    test "validate_contract with valid payload passes" do
      contract = %{
        "type" => "object",
        "required" => ["name"],
        "properties" => %{"name" => %{"type" => "string"}}
      }

      assert :ok = MappingHelper.validate_contract(contract, %{"name" => "Alice"})
    end

    test "validate_contract with invalid payload returns error" do
      contract = %{
        "type" => "object",
        "required" => ["name"],
        "properties" => %{"name" => %{"type" => "string"}}
      }

      assert {:error, violations} = MappingHelper.validate_contract(contract, %{"wrong" => 1})
      assert is_list(violations)
    end

    test "validate_contract with malformed schema returns error" do
      broken_schema = %{"type" => "nonexistent_type_that_will_break"}

      assert {:error, {:invalid_contract_schema, _msg}} =
               MappingHelper.validate_contract(broken_schema, %{"a" => 1})
    end
  end

  describe "UserTask — mapper/contract pipeline" do
    alias EvilEngine.BPMN.Model.Mapping

    defp user_task_node(opts) do
      %FlowNode{
        id: "ut1",
        type: :user_task,
        type_data: %FlowNodeData.UserTask{
          in_mappings: Keyword.get(opts, :in_mappings, []),
          out_mappings: Keyword.get(opts, :out_mappings, []),
          payload_contract: Keyword.get(opts, :payload_contract, nil),
          result_contract: Keyword.get(opts, :result_contract, nil)
        }
      }
    end

    test "UT: clean pipeline with all features — enter produces mapped input" do
      node =
        user_task_node(
          in_mappings: [%Mapping{source: "token.raw_name", target: "name"}],
          payload_contract: %{
            "type" => "object",
            "required" => ["name"],
            "properties" => %{"name" => %{"type" => "string"}}
          }
        )

      {node, context} = make_context(node)
      token = make_token(%{"raw_name" => "Alice"})

      assert {:wait, %FlowNodeResult{output_payload: payload}} =
               FlowNodes.UserTask.handle_enter(node, token, context)

      assert payload == %{"name" => "Alice"}
    end

    test "UT: corrupt input mapper causes error" do
      node =
        user_task_node(
          in_mappings: [%Mapping{source: "for x in [1] return if x then", target: "name"}]
        )

      {node, context} = make_context(node)
      token = make_token()

      assert {:error, {:in_mapping_failed, {:feel_eval_failed, _, _}}} =
               FlowNodes.UserTask.handle_enter(node, token, context)
    end

    test "UT: input contract violation causes error (fatal)" do
      node =
        user_task_node(
          payload_contract: %{
            "type" => "object",
            "required" => ["mandatory_field"],
            "properties" => %{"mandatory_field" => %{"type" => "integer"}}
          }
        )

      {node, context} = make_context(node)
      token = make_token(%{"wrong_field" => "data"})

      assert {:error, {:user_task_input_contract_violation, _violations}} =
               FlowNodes.UserTask.handle_enter(node, token, context)
    end

    test "UT: input mapper reshapes data to satisfy input contract" do
      node =
        user_task_node(
          in_mappings: [%Mapping{source: "token.raw_id", target: "mandatory_field"}],
          payload_contract: %{
            "type" => "object",
            "required" => ["mandatory_field"],
            "properties" => %{"mandatory_field" => %{"type" => "integer"}}
          }
        )

      {node, context} = make_context(node)
      token = make_token(%{"raw_id" => 42})

      assert {:wait, %FlowNodeResult{output_payload: %{"mandatory_field" => 42}}} =
               FlowNodes.UserTask.handle_enter(node, token, context)
    end

    test "UT: output contract violation returns error (retryable)" do
      contract = %{
        "type" => "object",
        "required" => ["approved"],
        "properties" => %{"approved" => %{"type" => "boolean"}}
      }

      node = %FlowNode{
        id: "ut1",
        type: :user_task,
        type_data: %FlowNodeData.UserTask{result_contract: contract}
      }

      entry = %{next_flow_node_ids: ["end1"]}
      context = %HandlerContext{flow_node_instance_id: "fni-1", process_instance_id: "pi-1"}

      assert {:error, {:contract_violation, _violations}} =
               FlowNodes.UserTask.handle_complete(node, entry, %{"wrong" => "data"}, context)
    end

    test "UT: output mapper transforms result before contract check" do
      base_node = %FlowNode{
        id: "ut1",
        type: :user_task,
        type_data: %FlowNodeData.UserTask{
          out_mappings: [%Mapping{source: "token.is_approved", target: "approved"}],
          result_contract: %{
            "type" => "object",
            "required" => ["approved"],
            "properties" => %{"approved" => %{"type" => "boolean"}}
          }
        }
      }

      {node, context} = make_complete_context(base_node)
      entry = %{next_flow_node_ids: ["end1"]}

      assert {:ok, %FlowNodeResult{output_payload: %{"approved" => true}}} =
               FlowNodes.UserTask.handle_complete(node, entry, %{"is_approved" => true}, context)
    end

    test "UT: corrupt output mapper causes error (fatal)" do
      base_node = %FlowNode{
        id: "ut1",
        type: :user_task,
        type_data: %FlowNodeData.UserTask{
          out_mappings: [%Mapping{source: "for x in [1] return if x then", target: "out"}]
        }
      }

      {node, context} = make_complete_context(base_node)
      entry = %{next_flow_node_ids: ["end1"]}

      assert {:error, {:out_mapping_failed, {:feel_eval_failed, _, _}}} =
               FlowNodes.UserTask.handle_complete(node, entry, %{"data" => 1}, context)
    end

    test "UT: mappers only (no contracts) — enter and complete succeed" do
      node = user_task_node(in_mappings: [%Mapping{source: "token.raw", target: "mapped"}])

      {node, context} = make_context(node)
      token = make_token(%{"raw" => "value"})

      assert {:wait, %FlowNodeResult{output_payload: %{"mapped" => "value"}}} =
               FlowNodes.UserTask.handle_enter(node, token, context)

      complete_base_node = %FlowNode{
        id: "ut1",
        type: :user_task,
        type_data: %FlowNodeData.UserTask{
          out_mappings: [%Mapping{source: "token.user_result", target: "final"}]
        }
      }

      {complete_node, complete_context} = make_complete_context(complete_base_node)
      entry = %{next_flow_node_ids: ["end1"]}

      assert {:ok, %FlowNodeResult{output_payload: %{"final" => "done"}}} =
               FlowNodes.UserTask.handle_complete(
                 complete_node,
                 entry,
                 %{"user_result" => "done"},
                 complete_context
               )
    end
  end

  describe "ServiceTask — async-only pipeline" do
    alias EvilEngine.BPMN.Model.Mapping
    alias EvilEngine.Execution.ServiceTaskDispatch

    defmodule MockAsyncHandler do
      @moduledoc false
      @behaviour EvilEngine.Plugin.ServiceTaskHandler

      @impl true
      def handle_enter(_flow_node, _token, context) do
        {:async, context.flow_node_instance_id}
      end
    end

    defmodule MockDispatch do
      @moduledoc false
      @behaviour ServiceTaskDispatch

      @impl true
      def lookup_handler("echo"), do: {:ok, MockAsyncHandler}
      def lookup_handler(_), do: {:error, :not_found}
    end

    setup do
      previous = Application.get_env(:core_execution, :service_task_dispatch)
      Application.put_env(:core_execution, :service_task_dispatch, MockDispatch)

      on_exit(fn ->
        if previous do
          Application.put_env(:core_execution, :service_task_dispatch, previous)
        else
          Application.delete_env(:core_execution, :service_task_dispatch)
        end
      end)

      :ok
    end

    defp service_task_node(opts) do
      %FlowNode{
        id: "st1",
        type: :service_task,
        type_data: %FlowNodeData.ServiceTask{
          implementation: Keyword.get(opts, :implementation, "echo"),
          in_mappings: Keyword.get(opts, :in_mappings, []),
          out_mappings: Keyword.get(opts, :out_mappings, []),
          payload_contract: Keyword.get(opts, :payload_contract, nil),
          result_contract: Keyword.get(opts, :result_contract, nil)
        }
      }
    end

    test "ST: handler returns {:async, fni_id}" do
      node = service_task_node([])
      {node, context} = make_context(node)
      token = make_token()

      assert {:async, "fni-1", %{persisted: true}} =
               FlowNodes.ServiceTask.handle_enter(node, token, context)
    end

    test "ST: corrupt input mapper causes error" do
      node =
        service_task_node(
          in_mappings: [%Mapping{source: "for x in [1] return if x then", target: "id"}]
        )

      {node, context} = make_context(node)
      token = make_token()

      assert {:error, {:in_mapping_failed, {:feel_eval_failed, _, _}}} =
               FlowNodes.ServiceTask.handle_enter(node, token, context)
    end

    test "ST: input contract violation causes error (fatal)" do
      node =
        service_task_node(
          payload_contract: %{
            "type" => "object",
            "required" => ["mandatory"],
            "properties" => %{"mandatory" => %{"type" => "integer"}}
          }
        )

      {node, context} = make_context(node)
      token = make_token(%{"wrong" => "data"})

      assert {:error, {:service_task_contract_violation, _}} =
               FlowNodes.ServiceTask.handle_enter(node, token, context)
    end

    test "ST: input mapper reshapes to satisfy payload contract, then returns async" do
      node =
        service_task_node(
          in_mappings: [%Mapping{source: "token.raw_id", target: "mandatory"}],
          payload_contract: %{
            "type" => "object",
            "required" => ["mandatory"],
            "properties" => %{"mandatory" => %{"type" => "integer"}}
          }
        )

      {node, context} = make_context(node)
      token = make_token(%{"raw_id" => 42})

      assert {:async, "fni-1", %{persisted: true}} =
               FlowNodes.ServiceTask.handle_enter(node, token, context)
    end

    test "ST: full input pipeline with valid mappings and contracts returns async" do
      node =
        service_task_node(
          in_mappings: [%Mapping{source: "token.order_id", target: "id"}],
          payload_contract: %{
            "type" => "object",
            "required" => ["id"],
            "properties" => %{"id" => %{"type" => "string"}}
          }
        )

      {node, context} = make_context(node)
      token = make_token(%{"order_id" => "ORD-123"})

      assert {:async, "fni-1", %{persisted: true}} =
               FlowNodes.ServiceTask.handle_enter(node, token, context)
    end

    test "ST: input mappers only (no contracts) returns async" do
      node = service_task_node(in_mappings: [%Mapping{source: "token.raw", target: "mapped"}])

      {node, context} = make_context(node)
      token = make_token(%{"raw" => "value"})

      assert {:async, "fni-1", %{persisted: true}} =
               FlowNodes.ServiceTask.handle_enter(node, token, context)
    end

    test "ST: malformed contract schema causes error" do
      node = service_task_node(payload_contract: %{"type" => "nonexistent_type_that_will_break"})

      {node, context} = make_context(node)
      token = make_token()

      assert {:error, {:service_task_contract_violation, {:invalid_contract_schema, _}}} =
               FlowNodes.ServiceTask.handle_enter(node, token, context)
    end

    test "ST: unknown implementation returns error" do
      node = service_task_node(implementation: "nonexistent")
      {node, context} = make_context(node)
      token = make_token()

      assert {:error, {:no_handler_for_implementation, "nonexistent"}} =
               FlowNodes.ServiceTask.handle_enter(node, token, context)
    end

    test "ST: handle_complete applies output pipeline" do
      node =
        service_task_node(
          out_mappings: [%Mapping{source: "token.raw_result", target: "final"}],
          result_contract: %{
            "type" => "object",
            "required" => ["final"],
            "properties" => %{"final" => %{"type" => "string"}}
          }
        )

      {node, context} = make_context(node)
      entry = %{}

      assert {:ok, %FlowNodeResult{output_payload: %{"final" => "done"}}} =
               FlowNodes.ServiceTask.handle_complete(
                 node,
                 entry,
                 %{"raw_result" => "done"},
                 context
               )
    end

    test "ST: handle_complete output contract violation causes error" do
      node =
        service_task_node(
          result_contract: %{
            "type" => "object",
            "required" => ["impossible_field"],
            "properties" => %{"impossible_field" => %{"type" => "integer"}}
          }
        )

      {node, context} = make_context(node)
      entry = %{}

      assert {:error, {:service_task_contract_violation, _}} =
               FlowNodes.ServiceTask.handle_complete(
                 node,
                 entry,
                 %{"wrong" => "data"},
                 context
               )
    end

    test "ST: handle_complete corrupt output mapper causes error" do
      node =
        service_task_node(
          out_mappings: [%Mapping{source: "for x in [1] return if x then", target: "out"}]
        )

      {node, context} = make_context(node)
      entry = %{}

      assert {:error, {:out_mapping_failed, {:feel_eval_failed, _, _}}} =
               FlowNodes.ServiceTask.handle_complete(
                 node,
                 entry,
                 %{"data" => 1},
                 context
               )
    end
  end

  describe "ScriptTask — inline FEEL and plugin dispatch (unit)" do
    alias EvilEngine.BPMN.Model.Mapping
    alias EvilEngine.Execution.ScriptDispatch

    defmodule MockNamedScript do
      @moduledoc false
      @behaviour EvilEngine.Plugin.NamedScript

      @impl true
      def handle_enter(_flow_node, payload, _context) do
        {:ok, Map.put(payload, "validated", true)}
      end
    end

    defmodule MockErrorNamedScript do
      @moduledoc false
      @behaviour EvilEngine.Plugin.NamedScript

      @impl true
      def handle_enter(_flow_node, _payload, _context) do
        {:error, :validation_failed}
      end
    end

    defmodule MockScriptDispatch do
      @moduledoc false
      @behaviour ScriptDispatch

      @impl true
      def lookup_script("my_validator"), do: {:ok, MockNamedScript}
      def lookup_script("failing_script"), do: {:ok, MockErrorNamedScript}
      def lookup_script(_), do: {:error, :not_found}
    end

    setup do
      previous = Application.get_env(:core_execution, :script_dispatch)
      Application.put_env(:core_execution, :script_dispatch, MockScriptDispatch)

      on_exit(fn ->
        if previous do
          Application.put_env(:core_execution, :script_dispatch, previous)
        else
          Application.delete_env(:core_execution, :script_dispatch)
        end
      end)

      :ok
    end

    defp script_task_node(opts \\ []) do
      %FlowNode{
        id: "sc1",
        type: :script_task,
        type_data: %FlowNodeData.ScriptTask{
          script: Keyword.get(opts, :script, nil),
          script_ref: Keyword.get(opts, :script_ref, nil),
          script_format: Keyword.get(opts, :script_format, nil),
          in_mappings: Keyword.get(opts, :in_mappings, []),
          out_mappings: Keyword.get(opts, :out_mappings, []),
          payload_contract: Keyword.get(opts, :payload_contract, nil),
          result_contract: Keyword.get(opts, :result_contract, nil)
        }
      }
    end

    test "SCR: inline FEEL script evaluates and produces output" do
      node = script_task_node(script: "token.amount * 2")
      {node, context} = make_context(node)
      token = make_token(%{"amount" => 10})

      assert {:ok, %FlowNodeResult{output_payload: payload}} =
               FlowNodes.ScriptTask.handle_enter(node, token, context)

      assert payload == %{"result" => 20}
    end

    test "SCR: inline FEEL returning map passes through as-is" do
      node = script_task_node(script: ~s|{"doubled": token.amount * 2, "original": token.amount}|)
      {node, context} = make_context(node)
      token = make_token(%{"amount" => 5})

      assert {:ok, %FlowNodeResult{output_payload: payload}} =
               FlowNodes.ScriptTask.handle_enter(node, token, context)

      assert payload["doubled"] == 10
      assert payload["original"] == 5
    end

    test "SCR: 'this' binding exposes flow node metadata, not token payload" do
      node =
        script_task_node(
          script: ~s|{ node_id: this.id, node_type: this.type, node_name: this.name }|
        )

      node = %{node | name: "Calculate Discount"}
      {node, context} = make_context(node)
      token = make_token(%{"id" => "token-level-id", "type" => "ignored"})

      assert {:ok, %FlowNodeResult{output_payload: payload}} =
               FlowNodes.ScriptTask.handle_enter(node, token, context)

      assert payload["node_id"] == "sc1"
      assert payload["node_type"] == "script_task"
      assert payload["node_name"] == "Calculate Discount"
    end

    test "SCR: scriptRef dispatches to named script handler" do
      node = script_task_node(script_ref: "my_validator")
      {node, context} = make_context(node)
      token = make_token(%{"data" => "test"})

      assert {:ok, %FlowNodeResult{output_payload: payload}} =
               FlowNodes.ScriptTask.handle_enter(node, token, context)

      assert payload == %{"data" => "test", "validated" => true}
    end

    test "SCR: scriptRef takes precedence over inline script" do
      node = script_task_node(script: "token.x + 1", script_ref: "my_validator")
      {node, context} = make_context(node)
      token = make_token(%{"x" => 99})

      assert {:ok, %FlowNodeResult{output_payload: payload}} =
               FlowNodes.ScriptTask.handle_enter(node, token, context)

      assert payload["validated"] == true
    end

    test "SCR: missing script AND scriptRef returns error" do
      node = script_task_node()
      {node, context} = make_context(node)
      token = make_token()

      assert {:error, {:missing_script, _}} =
               FlowNodes.ScriptTask.handle_enter(node, token, context)
    end

    test "SCR: input mapping + payload contract + inline script (happy path)" do
      node =
        script_task_node(
          script: "token.input_value * 2",
          in_mappings: [%Mapping{source: "token.raw_amount", target: "input_value"}],
          payload_contract: %{
            "type" => "object",
            "required" => ["input_value"],
            "properties" => %{"input_value" => %{"type" => "integer"}}
          }
        )

      {node, context} = make_context(node)
      token = make_token(%{"raw_amount" => 50})

      assert {:ok, %FlowNodeResult{output_payload: %{"result" => 100}}} =
               FlowNodes.ScriptTask.handle_enter(node, token, context)
    end

    test "SCR: corrupt input FEEL mapping returns fatal" do
      node =
        script_task_node(
          script: "token.x",
          in_mappings: [%Mapping{source: "for x in [1] return if x then", target: "x"}]
        )

      {node, context} = make_context(node)
      token = make_token()

      assert {:error, {:in_mapping_failed, {:feel_eval_failed, _, _}}} =
               FlowNodes.ScriptTask.handle_enter(node, token, context)
    end

    test "SCR: payload contract violation returns fatal" do
      node =
        script_task_node(
          script: "token.x",
          payload_contract: %{
            "type" => "object",
            "required" => ["mandatory"],
            "properties" => %{"mandatory" => %{"type" => "integer"}}
          }
        )

      {node, context} = make_context(node)
      token = make_token(%{"wrong" => "data"})

      assert {:error, {:script_task_contract_violation, _}} =
               FlowNodes.ScriptTask.handle_enter(node, token, context)
    end

    test "SCR: output mapping + result contract (happy path)" do
      node =
        script_task_node(
          script: "token.amount * 3",
          out_mappings: [%Mapping{source: "token.result", target: "tripled"}],
          result_contract: %{
            "type" => "object",
            "required" => ["tripled"],
            "properties" => %{"tripled" => %{"type" => "integer"}}
          }
        )

      {node, context} = make_context(node)
      token = make_token(%{"amount" => 10})

      assert {:ok, %FlowNodeResult{output_payload: %{"tripled" => 30}}} =
               FlowNodes.ScriptTask.handle_enter(node, token, context)
    end

    test "SCR: corrupt output FEEL mapping returns fatal" do
      node =
        script_task_node(
          script: "token.amount",
          out_mappings: [%Mapping{source: "for x in [1] return if x then", target: "out"}]
        )

      {node, context} = make_context(node)
      token = make_token(%{"amount" => 10})

      assert {:error, {:out_mapping_failed, {:feel_eval_failed, _, _}}} =
               FlowNodes.ScriptTask.handle_enter(node, token, context)
    end

    test "SCR: result contract violation returns fatal" do
      node =
        script_task_node(
          script: "token.amount",
          result_contract: %{
            "type" => "object",
            "required" => ["impossible_field"],
            "properties" => %{"impossible_field" => %{"type" => "integer"}}
          }
        )

      {node, context} = make_context(node)
      token = make_token(%{"amount" => 10})

      assert {:error, {:script_task_contract_violation, _}} =
               FlowNodes.ScriptTask.handle_enter(node, token, context)
    end

    test "SCR: FEEL evaluation error returns fatal (corrupt script syntax)" do
      node = script_task_node(script: "for x in [1] return if x then")
      {node, context} = make_context(node)
      token = make_token()

      assert {:error, {:script_eval_failed, _, _}} =
               FlowNodes.ScriptTask.handle_enter(node, token, context)
    end

    test "SCR: named script returning error propagates as fatal" do
      node = script_task_node(script_ref: "failing_script")
      {node, context} = make_context(node)
      token = make_token()

      assert {:error, {:named_script_failed, "failing_script", :validation_failed}} =
               FlowNodes.ScriptTask.handle_enter(node, token, context)
    end

    test "SCR: unknown scriptRef returns not-found error" do
      node = script_task_node(script_ref: "nonexistent_plugin")
      {node, context} = make_context(node)
      token = make_token()

      assert {:error, {:no_handler_for_script_ref, "nonexistent_plugin"}} =
               FlowNodes.ScriptTask.handle_enter(node, token, context)
    end
  end

  describe "LinkThrowEvent" do
    alias EvilEngine.BPMN.Model.EventDefinition

    defp link_throw_node(link_name) do
      %FlowNode{
        id: "link-throw-1",
        type: :intermediate_throw_event,
        type_data: %FlowNodeData.IntermediateThrowEvent{
          event_definition: %EventDefinition.Link{link_name: link_name}
        }
      }
    end

    defp link_catch_node(id, link_name) do
      %FlowNode{
        id: id,
        type: :intermediate_catch_event,
        type_data: %FlowNodeData.IntermediateCatchEvent{
          event_definition: %EventDefinition.Link{link_name: link_name}
        }
      }
    end

    defp make_link_context(throw_node, extra_nodes) do
      process_model = %BpmnProcess{
        id: "proc-1",
        flow_nodes: [throw_node | extra_nodes],
        sequence_flows: []
      }

      context = %HandlerContext{
        flow_node_instance_id: "fni-1",
        process_instance_id: "pi-1",
        process_model: process_model
      }

      {throw_node, context}
    end

    test "routes token to the matching Link Catch event" do
      throw_node = link_throw_node("A")
      catch_node = link_catch_node("link-catch-A", "A")
      {throw_node, context} = make_link_context(throw_node, [catch_node])
      token = make_token(%{"order" => "123"})

      assert {:ok, %FlowNodeResult{} = result} =
               FlowNodes.LinkThrowEvent.handle_enter(throw_node, token, context)

      assert result.next_flow_node_ids == ["link-catch-A"]
    end

    test "passes payload through unchanged" do
      throw_node = link_throw_node("A")
      catch_node = link_catch_node("link-catch-A", "A")
      {throw_node, context} = make_link_context(throw_node, [catch_node])
      payload = %{"order" => "123", "amount" => 42}
      token = make_token(payload)

      assert {:ok, %FlowNodeResult{} = result} =
               FlowNodes.LinkThrowEvent.handle_enter(throw_node, token, context)

      assert result.output_payload == payload
    end

    test "returns error when no matching Link Catch exists" do
      throw_node = link_throw_node("X")
      {throw_node, context} = make_link_context(throw_node, [])
      token = make_token()

      assert {:error, %{reason: :no_matching_link_catch, link_name: "X"}} =
               FlowNodes.LinkThrowEvent.handle_enter(throw_node, token, context)
    end

    test "returns error when multiple Link Catches share the same name" do
      throw_node = link_throw_node("A")
      catch_1 = link_catch_node("catch-A1", "A")
      catch_2 = link_catch_node("catch-A2", "A")
      {throw_node, context} = make_link_context(throw_node, [catch_1, catch_2])
      token = make_token()

      assert {:error, %{reason: :ambiguous_link_catch, link_name: "A", catch_count: 2}} =
               FlowNodes.LinkThrowEvent.handle_enter(throw_node, token, context)
    end

    test "ignores Link Catches with different names" do
      throw_node = link_throw_node("A")
      catch_a = link_catch_node("catch-A", "A")
      catch_b = link_catch_node("catch-B", "B")
      {throw_node, context} = make_link_context(throw_node, [catch_a, catch_b])
      token = make_token()

      assert {:ok, %FlowNodeResult{} = result} =
               FlowNodes.LinkThrowEvent.handle_enter(throw_node, token, context)

      assert result.next_flow_node_ids == ["catch-A"]
    end
  end

  describe "LinkCatchEvent" do
    alias EvilEngine.BPMN.Model.EventDefinition

    test "passes through via outgoing sequence flows" do
      base_node = %FlowNode{
        id: "link-catch-1",
        type: :intermediate_catch_event,
        type_data: %FlowNodeData.IntermediateCatchEvent{
          event_definition: %EventDefinition.Link{link_name: "A"}
        }
      }

      {node, context} = make_context(base_node)
      token = make_token(%{"order" => "123"})

      assert {:ok, %FlowNodeResult{} = result} =
               FlowNodes.LinkCatchEvent.handle_enter(node, token, context)

      assert result.next_flow_node_ids == ["next-node"]
    end

    test "passes payload through unchanged" do
      base_node = %FlowNode{
        id: "link-catch-1",
        type: :intermediate_catch_event,
        type_data: %FlowNodeData.IntermediateCatchEvent{
          event_definition: %EventDefinition.Link{link_name: "A"}
        }
      }

      {node, context} = make_context(base_node)
      payload = %{"order" => "123", "amount" => 42}
      token = make_token(payload)

      assert {:ok, %FlowNodeResult{} = result} =
               FlowNodes.LinkCatchEvent.handle_enter(node, token, context)

      assert result.output_payload == payload
    end
  end

  describe "Token creation" do
    test "token struct can be created with required fields" do
      token = %Token{
        id: "t1",
        process_instance_id: "pi-1",
        payload: %{"data" => 42},
        originating_flow_node_instance_id: "fni-1",
        created_at: DateTime.utc_now()
      }

      assert token.id == "t1"
      assert token.process_instance_id == "pi-1"
      assert token.payload == %{"data" => 42}
      assert token.originating_flow_node_instance_id == "fni-1"
    end
  end
end
