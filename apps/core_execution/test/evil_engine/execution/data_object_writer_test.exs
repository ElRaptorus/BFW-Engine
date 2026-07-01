defmodule EvilEngine.Execution.DataObjectWriterTest do
  use ExUnit.Case, async: true

  alias EvilEngine.BPMN.Model.DataAssociation
  alias EvilEngine.BPMN.Model.DataObject
  alias EvilEngine.BPMN.Model.DataObjectReference
  alias EvilEngine.BPMN.Model.FlowNode
  alias EvilEngine.BPMN.Model.FlowNodeData
  alias EvilEngine.BPMN.Model.Process, as: BpmnProcess
  alias EvilEngine.Execution.DataObjectWriteIntent
  alias EvilEngine.Execution.DataObjectWriter
  alias EvilEngine.Execution.HandlerContext
  alias EvilEngine.Execution.ProcessInstance.State
  alias EvilEngine.Expressions.Context, as: FeelContext

  defp build_handler_context(flow_node, state) do
    %HandlerContext{
      flow_node_instance_id: "fni-1",
      process_instance_id: state.process_instance_id,
      process_model: state.process_model,
      flow_node_this: FeelContext.flow_node_this(flow_node),
      context: %{},
      identity: %{id: "test-user", roles: ["admin"]},
      process: %{id: state.process_model.id, name: "Test Process", version: "1.0"},
      process_instance: %{
        id: state.process_instance_id,
        started_at: DateTime.utc_now(),
        started_by: "test-user"
      },
      data_objects: state.data_object_cache
    }
  end

  defp call_prepare(flow_node, fni_id, output, state, handler_context) do
    DataObjectWriter.prepare_associations(
      flow_node,
      fni_id,
      output,
      state.data_object_cache,
      state.process_model,
      handler_context
    )
  end

  defp build_state(opts \\ []) do
    data_objects = Keyword.get(opts, :data_objects, [%DataObject{id: "DO_1"}])

    data_object_references =
      Keyword.get(opts, :data_object_references, [
        %DataObjectReference{id: "DOR_1", data_object_ref: "DO_1"}
      ])

    cache = Keyword.get(opts, :cache, %{})

    %State{
      process_instance_id: "pi-test-001",
      process_version_id: "pv-test-001",
      process_model: %BpmnProcess{
        id: "P1",
        version: "1.0",
        data_objects: data_objects,
        data_object_references: data_object_references,
        flow_nodes: [],
        sequence_flows: []
      },
      data_object_cache: cache
    }
  end

  defp build_flow_node(doa_list) do
    %FlowNode{
      id: "Task_1",
      type: :task,
      type_data: %FlowNodeData.Task{},
      data_output_associations: doa_list
    }
  end

  describe "prepare_associations/6" do
    test "empty data_output_associations returns unchanged cache and no intents" do
      state = build_state()
      flow_node = build_flow_node([])
      handler_context = build_handler_context(flow_node, state)

      assert {:ok, %{}, []} =
               call_prepare(flow_node, "fni-1", %{"x" => 1}, state, handler_context)
    end

    test "DOA without expression produces intent with full output_payload" do
      state = build_state()
      doa = %DataAssociation{id: "DOA_1", target_ref: "DOR_1", value_expression: nil}
      flow_node = build_flow_node([doa])
      handler_context = build_handler_context(flow_node, state)

      assert {:ok, cache, [intent]} =
               call_prepare(flow_node, "fni-1", %{"x" => 42}, state, handler_context)

      assert cache["DO_1"] == %{"x" => 42}
      assert %DataObjectWriteIntent{} = intent
      assert intent.data_object_id == "DO_1"
      assert intent.value == %{"x" => 42}
      assert intent.previous_value == nil
      assert intent.process_instance_id == "pi-test-001"
      assert intent.flow_node_instance_id == "fni-1"
    end

    test "DOA with FEEL expression produces intent with evaluated value" do
      state = build_state()
      doa = %DataAssociation{id: "DOA_1", target_ref: "DOR_1", value_expression: "token.x + 10"}
      flow_node = build_flow_node([doa])
      handler_context = build_handler_context(flow_node, state)

      assert {:ok, cache, [intent]} =
               call_prepare(flow_node, "fni-1", %{"x" => 5}, state, handler_context)

      assert cache["DO_1"] == 15
      assert intent.value == 15
    end

    test "multiple DOAs on one flow node: all intents produced" do
      state =
        build_state(
          data_objects: [%DataObject{id: "DO_1"}, %DataObject{id: "DO_2"}],
          data_object_references: [
            %DataObjectReference{id: "DOR_1", data_object_ref: "DO_1"},
            %DataObjectReference{id: "DOR_2", data_object_ref: "DO_2"}
          ]
        )

      doas = [
        %DataAssociation{id: "DOA_1", target_ref: "DOR_1", value_expression: nil},
        %DataAssociation{id: "DOA_2", target_ref: "DOR_2", value_expression: "token.b"}
      ]

      flow_node = build_flow_node(doas)
      handler_context = build_handler_context(flow_node, state)

      assert {:ok, cache, intents} =
               call_prepare(flow_node, "fni-1", %{"a" => 1, "b" => 2}, state, handler_context)

      assert length(intents) == 2
      assert cache["DO_1"] == %{"a" => 1, "b" => 2}
      assert cache["DO_2"] == 2

      [i1, i2] = intents
      assert i1.data_object_id == "DO_1"
      assert i2.data_object_id == "DO_2"
      assert i2.value == 2
    end

    test "DOA targeting unknown DataObjectReference returns error" do
      state = build_state()
      doa = %DataAssociation{id: "DOA_1", target_ref: "NONEXISTENT"}
      flow_node = build_flow_node([doa])
      handler_context = build_handler_context(flow_node, state)

      assert {:error, {:unknown_data_object_reference, "NONEXISTENT"}} =
               call_prepare(flow_node, "fni-1", %{}, state, handler_context)
    end

    test "DOA with corrupt FEEL expression returns error" do
      state = build_state()
      doa = %DataAssociation{id: "DOA_1", target_ref: "DOR_1", value_expression: "###INVALID###"}
      flow_node = build_flow_node([doa])
      handler_context = build_handler_context(flow_node, state)

      assert {:error, {:feel_eval_failed, "###INVALID###", _reason}} =
               call_prepare(flow_node, "fni-1", %{"x" => 1}, state, handler_context)
    end

    test "value contract violation returns error" do
      contract = %{"type" => "object", "required" => ["name"]}
      state = build_state(data_objects: [%DataObject{id: "DO_1", value_contract: contract}])
      doa = %DataAssociation{id: "DOA_1", target_ref: "DOR_1", value_expression: nil}
      flow_node = build_flow_node([doa])
      handler_context = build_handler_context(flow_node, state)

      assert {:error, {:value_contract_violation, "DO_1", _violations}} =
               call_prepare(flow_node, "fni-1", %{"x" => 1}, state, handler_context)
    end

    test "value contract passes when data satisfies schema" do
      contract = %{"type" => "object", "required" => ["name"]}
      state = build_state(data_objects: [%DataObject{id: "DO_1", value_contract: contract}])
      doa = %DataAssociation{id: "DOA_1", target_ref: "DOR_1", value_expression: nil}
      flow_node = build_flow_node([doa])
      handler_context = build_handler_context(flow_node, state)

      assert {:ok, cache, [intent]} =
               call_prepare(flow_node, "fni-1", %{"name" => "test"}, state, handler_context)

      assert cache["DO_1"] == %{"name" => "test"}
      assert intent.value == %{"name" => "test"}
    end

    test "previous value tracked correctly (nil for first, old for subsequent)" do
      state = build_state(cache: %{"DO_1" => %{"old" => "value"}})
      doa = %DataAssociation{id: "DOA_1", target_ref: "DOR_1", value_expression: nil}
      flow_node = build_flow_node([doa])
      handler_context = build_handler_context(flow_node, state)

      assert {:ok, cache, [intent]} =
               call_prepare(flow_node, "fni-1", %{"new" => "value"}, state, handler_context)

      assert cache["DO_1"] == %{"new" => "value"}
      assert intent.previous_value == %{"old" => "value"}
      assert intent.value == %{"new" => "value"}
    end

    test "multiple writes to same DataObject: last value wins in cache" do
      state =
        build_state(
          data_object_references: [
            %DataObjectReference{id: "DOR_1", data_object_ref: "DO_1"},
            %DataObjectReference{id: "DOR_2", data_object_ref: "DO_1"}
          ]
        )

      doas = [
        %DataAssociation{id: "DOA_1", target_ref: "DOR_1", value_expression: "\"first\""},
        %DataAssociation{id: "DOA_2", target_ref: "DOR_2", value_expression: "\"second\""}
      ]

      flow_node = build_flow_node(doas)
      handler_context = build_handler_context(flow_node, state)

      assert {:ok, cache, intents} =
               call_prepare(flow_node, "fni-1", %{}, state, handler_context)

      assert cache["DO_1"] == "second"
      assert length(intents) == 2
      [i1, i2] = intents
      assert i1.value == "first"
      assert i2.value == "second"
      assert i2.previous_value == "first"
    end

    test "nil value_contract on DataObject allows any value through" do
      state = build_state(data_objects: [%DataObject{id: "DO_1", value_contract: nil}])
      doa = %DataAssociation{id: "DOA_1", target_ref: "DOR_1", value_expression: nil}
      flow_node = build_flow_node([doa])
      handler_context = build_handler_context(flow_node, state)

      assert {:ok, cache, [_intent]} =
               call_prepare(flow_node, "fni-1", %{"anything" => "goes"}, state, handler_context)

      assert cache["DO_1"] == %{"anything" => "goes"}
    end

    test "PayloadCap violation returns structured error" do
      prev = Application.get_env(:core_execution, :token_max_bytes)
      Application.put_env(:core_execution, :token_max_bytes, 1024)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:core_execution, :token_max_bytes, prev),
          else: Application.delete_env(:core_execution, :token_max_bytes)
      end)

      state = build_state()
      oversize = %{"blob" => String.duplicate("x", 2000)}
      doa = %DataAssociation{id: "DOA_1", target_ref: "DOR_1", value_expression: nil}
      flow_node = build_flow_node([doa])
      handler_context = build_handler_context(flow_node, state)

      assert {:error, {:payload_too_large, details}} =
               call_prepare(flow_node, "fni-1", oversize, state, handler_context)

      assert details.field == :data_object_value
      assert details.size > 1024
    end

    test "DOA targeting known DOR but with missing DataObject returns error" do
      state =
        build_state(
          data_object_references: [
            %DataObjectReference{id: "DOR_1", data_object_ref: "DO_MISSING"}
          ],
          data_objects: []
        )

      doa = %DataAssociation{id: "DOA_1", target_ref: "DOR_1"}
      flow_node = build_flow_node([doa])
      handler_context = build_handler_context(flow_node, state)

      assert {:error, {:unknown_data_object, "DO_MISSING"}} =
               call_prepare(flow_node, "fni-1", %{}, state, handler_context)
    end
  end
end
