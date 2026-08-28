defmodule EvilEngine.Execution.EventTypeExtractionTest do
  @moduledoc """
  Verifies that `event_type` is correctly derived from the BPMN model's
  event definitions and persisted via the adapter's `create_flow_node_instance/1`.

  Uses a capturing adapter that stores the attributes map for each FNI
  create call, allowing direct inspection of the `event_type` value
  without needing a database.
  """

  use ExUnit.Case, async: false

  alias EvilEngine.BPMN.Model.Definitions
  alias EvilEngine.BPMN.Model.EventDefinition
  alias EvilEngine.BPMN.Model.FlowNode
  alias EvilEngine.BPMN.Model.FlowNodeData
  alias EvilEngine.BPMN.Model.Process, as: BpmnProcess
  alias EvilEngine.BPMN.Model.SequenceFlow
  alias EvilEngine.BPMN.ModelCache
  alias EvilEngine.Execution
  alias EvilEngine.Types.Identity

  @version_id "00000000-0000-0000-0000-event-type-01"

  defmodule CapturingAdapter do
    @moduledoc false
    @behaviour EvilEngine.Execution.Persistence

    @impl true
    def create_process_instance(attributes), do: {:ok, attributes}

    @impl true
    def update_process_instance(_id, _changes), do: :ok

    @impl true
    def create_flow_node_instance(attributes) do
      :persistent_term.get(:event_type_test_pid) |> send({:fni_created, attributes})
      {:ok, attributes}
    end

    @impl true
    def update_flow_node_instance(_id, _action, _changes), do: :ok

    @impl true
    def list_running_process_instances(_opts), do: {:ok, %{records: [], next_cursor: nil}}

    @impl true
    def list_flow_node_instances(_id), do: {:ok, []}

    @impl true
    def finish_fni_with_data_objects(_fni_id, fni_changes, intents) do
      now = DateTime.utc_now()
      writes = Enum.map(intents, fn _intent -> %{write_id: "mock", created_at: now} end)
      {:ok, Map.put(fni_changes, :writes, writes)}
    end

    @impl true
    def write_data_object(_params), do: {:ok, %{write_id: "mock", created_at: DateTime.utc_now()}}

    @impl true
    def list_data_objects(_process_instance_id), do: {:ok, []}

    @impl true
    def cleanup_orphaned_flow_node_instances, do: {:ok, 0}

    @impl true
    def cleanup_orphaned_process_instances, do: {:ok, 0}

    @impl true
    def get_process_instance_for_retry(_id), do: {:error, :not_found}

    @impl true
    def list_all_flow_node_instances(_id), do: {:ok, []}

    @impl true
    def count_all_flow_node_instances(_id), do: {:ok, 0}

    @impl true
    def get_flow_node_instance_by_id(_id), do: {:error, :not_found}

    @impl true
    def execute_retry_reset(_id, _opts), do: {:ok, []}

    @impl true
    def revert_retry(_id, _state, _finished_at), do: :ok
    @impl true
    def list_child_process_instances(_), do: {:ok, []}
    @impl true
    def patch_fni_type_properties(_, _), do: :ok
    @impl true
    def create_gateway_pending_arrival(_params), do: :ok
    @impl true
    def list_gateway_pending_arrivals(_process_instance_id), do: {:ok, []}
    @impl true
    def delete_gateway_pending_arrivals_for_gateway(_fni_id), do: :ok
  end

  setup do
    Application.put_env(:core_execution, :persistence_adapter, CapturingAdapter)
    ModelCache.reset_state()
    :persistent_term.put(:event_type_test_pid, self())

    on_exit(fn ->
      Application.delete_env(:core_execution, :persistence_adapter)
      ModelCache.reset_state()
      :persistent_term.erase(:event_type_test_pid)
    end)
  end

  defp start_and_collect(definitions, opts \\ []) do
    ModelCache.put_new(@version_id, definitions)

    {:ok, pid} =
      Execution.start_process_instance(%{
        process_instance_id: random_id(),
        process_version_id: @version_id,
        payload: %{},
        identity: %Identity{id: "test", roles: ["admin"], groups: []},
        start_event_id: Keyword.get(opts, :start_event_id)
      })

    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 2_000

    collect_fni_creates()
  end

  defp collect_fni_creates(accumulated \\ []) do
    receive do
      {:fni_created, attributes} -> collect_fni_creates([attributes | accumulated])
    after
      100 -> Enum.reverse(accumulated)
    end
  end

  defp random_id, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

  defp build_process(nodes, flows) do
    %Definitions{
      processes: [
        %BpmnProcess{
          id: "test-process",
          name: "Test",
          version: "1.0.0",
          is_executable: true,
          flow_nodes: nodes,
          sequence_flows: flows
        }
      ],
      raw_xml: ""
    }
  end

  describe "event_type for event-shaped flow nodes" do
    test "plain start/end events have nil event_type" do
      definitions =
        build_process(
          [
            %FlowNode{
              id: "S1",
              type: :start_event,
              type_data: %FlowNodeData.StartEvent{event_definition: %EventDefinition.None{}},
              outgoing: ["F1"]
            },
            %FlowNode{
              id: "E1",
              type: :end_event,
              type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
              incoming: ["F1"]
            }
          ],
          [%SequenceFlow{id: "F1", source_ref: "S1", target_ref: "E1"}]
        )

      fnis = start_and_collect(definitions)
      start_fni = Enum.find(fnis, &(&1.flow_node_id == "S1"))
      end_fni = Enum.find(fnis, &(&1.flow_node_id == "E1"))

      assert start_fni.event_type == nil
      assert end_fni.event_type == nil
    end

    test "error end event has event_type \"error\"" do
      definitions =
        build_process(
          [
            %FlowNode{
              id: "S1",
              type: :start_event,
              type_data: %FlowNodeData.StartEvent{event_definition: %EventDefinition.None{}},
              outgoing: ["F1"]
            },
            %FlowNode{
              id: "E1",
              type: :end_event,
              type_data: %FlowNodeData.EndEvent{
                event_definition: %EventDefinition.Error{error_code: "FAIL"}
              },
              incoming: ["F1"]
            }
          ],
          [%SequenceFlow{id: "F1", source_ref: "S1", target_ref: "E1"}]
        )

      fnis = start_and_collect(definitions)
      end_fni = Enum.find(fnis, &(&1.flow_node_id == "E1"))

      assert end_fni.event_type == "error"
    end

    test "terminate end event has event_type \"terminate\"" do
      definitions =
        build_process(
          [
            %FlowNode{
              id: "S1",
              type: :start_event,
              type_data: %FlowNodeData.StartEvent{event_definition: %EventDefinition.None{}},
              outgoing: ["F1"]
            },
            %FlowNode{
              id: "E1",
              type: :end_event,
              type_data: %FlowNodeData.EndEvent{
                event_definition: %EventDefinition.Terminate{}
              },
              incoming: ["F1"]
            }
          ],
          [%SequenceFlow{id: "F1", source_ref: "S1", target_ref: "E1"}]
        )

      fnis = start_and_collect(definitions)
      end_fni = Enum.find(fnis, &(&1.flow_node_id == "E1"))

      assert end_fni.event_type == "terminate"
    end

    test "message end event has event_type \"message\"" do
      definitions =
        build_process(
          [
            %FlowNode{
              id: "S1",
              type: :start_event,
              type_data: %FlowNodeData.StartEvent{event_definition: %EventDefinition.None{}},
              outgoing: ["F1"]
            },
            %FlowNode{
              id: "E1",
              type: :end_event,
              type_data: %FlowNodeData.EndEvent{
                event_definition: %EventDefinition.Message{message_ref: "Msg_1"}
              },
              incoming: ["F1"]
            }
          ],
          [%SequenceFlow{id: "F1", source_ref: "S1", target_ref: "E1"}]
        )

      fnis = start_and_collect(definitions)
      end_fni = Enum.find(fnis, &(&1.flow_node_id == "E1"))

      assert end_fni.event_type == "message"
    end

    test "intermediate catch event with timer has event_type \"timer\"" do
      definitions =
        build_process(
          [
            %FlowNode{
              id: "S1",
              type: :start_event,
              type_data: %FlowNodeData.StartEvent{event_definition: %EventDefinition.None{}},
              outgoing: ["F1"]
            },
            %FlowNode{
              id: "ICE1",
              type: :intermediate_catch_event,
              type_data: %FlowNodeData.IntermediateCatchEvent{
                event_definition: %EventDefinition.Timer{time_duration: "PT1S"}
              },
              incoming: ["F1"],
              outgoing: ["F2"]
            },
            %FlowNode{
              id: "E1",
              type: :end_event,
              type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
              incoming: ["F2"]
            }
          ],
          [
            %SequenceFlow{id: "F1", source_ref: "S1", target_ref: "ICE1"},
            %SequenceFlow{id: "F2", source_ref: "ICE1", target_ref: "E1"}
          ]
        )

      fnis = start_and_collect(definitions)
      timer_fni = Enum.find(fnis, &(&1.flow_node_id == "ICE1"))

      assert timer_fni.event_type == "timer"
    end

    test "signal end event has event_type \"signal\"" do
      definitions =
        build_process(
          [
            %FlowNode{
              id: "S1",
              type: :start_event,
              type_data: %FlowNodeData.StartEvent{event_definition: %EventDefinition.None{}},
              outgoing: ["F1"]
            },
            %FlowNode{
              id: "E1",
              type: :end_event,
              type_data: %FlowNodeData.EndEvent{
                event_definition: %EventDefinition.Signal{signal_ref: "Sig_1"}
              },
              incoming: ["F1"]
            }
          ],
          [%SequenceFlow{id: "F1", source_ref: "S1", target_ref: "E1"}]
        )

      fnis = start_and_collect(definitions)
      end_fni = Enum.find(fnis, &(&1.flow_node_id == "E1"))

      assert end_fni.event_type == "signal"
    end
  end

  describe "event_type for non-event flow nodes" do
    test "task has nil event_type" do
      definitions =
        build_process(
          [
            %FlowNode{
              id: "S1",
              type: :start_event,
              type_data: %FlowNodeData.StartEvent{event_definition: %EventDefinition.None{}},
              outgoing: ["F1"]
            },
            %FlowNode{
              id: "T1",
              type: :task,
              type_data: %FlowNodeData.Task{},
              incoming: ["F1"],
              outgoing: ["F2"]
            },
            %FlowNode{
              id: "E1",
              type: :end_event,
              type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
              incoming: ["F2"]
            }
          ],
          [
            %SequenceFlow{id: "F1", source_ref: "S1", target_ref: "T1"},
            %SequenceFlow{id: "F2", source_ref: "T1", target_ref: "E1"}
          ]
        )

      fnis = start_and_collect(definitions)
      task_fni = Enum.find(fnis, &(&1.flow_node_id == "T1"))

      assert task_fni.event_type == nil
    end

    test "service_task has nil event_type" do
      definitions =
        build_process(
          [
            %FlowNode{
              id: "S1",
              type: :start_event,
              type_data: %FlowNodeData.StartEvent{event_definition: %EventDefinition.None{}},
              outgoing: ["F1"]
            },
            %FlowNode{
              id: "ST1",
              type: :service_task,
              type_data: %FlowNodeData.ServiceTask{implementation: "echo"},
              incoming: ["F1"],
              outgoing: ["F2"]
            },
            %FlowNode{
              id: "E1",
              type: :end_event,
              type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
              incoming: ["F2"]
            }
          ],
          [
            %SequenceFlow{id: "F1", source_ref: "S1", target_ref: "ST1"},
            %SequenceFlow{id: "F2", source_ref: "ST1", target_ref: "E1"}
          ]
        )

      fnis = start_and_collect(definitions)
      service_fni = Enum.find(fnis, &(&1.flow_node_id == "ST1"))

      assert service_fni.event_type == nil
    end
  end

  describe "event_type for message-oriented tasks" do
    test "send_task has event_type \"message\"" do
      definitions =
        build_process(
          [
            %FlowNode{
              id: "S1",
              type: :start_event,
              type_data: %FlowNodeData.StartEvent{event_definition: %EventDefinition.None{}},
              outgoing: ["F1"]
            },
            %FlowNode{
              id: "Send1",
              type: :send_task,
              type_data: %FlowNodeData.SendTask{message_ref: "Msg_1"},
              incoming: ["F1"],
              outgoing: ["F2"]
            },
            %FlowNode{
              id: "E1",
              type: :end_event,
              type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
              incoming: ["F2"]
            }
          ],
          [
            %SequenceFlow{id: "F1", source_ref: "S1", target_ref: "Send1"},
            %SequenceFlow{id: "F2", source_ref: "Send1", target_ref: "E1"}
          ]
        )

      fnis = start_and_collect(definitions)
      send_fni = Enum.find(fnis, &(&1.flow_node_id == "Send1"))

      assert send_fni.event_type == "message"
    end

    test "receive_task has event_type \"message\"" do
      definitions =
        build_process(
          [
            %FlowNode{
              id: "S1",
              type: :start_event,
              type_data: %FlowNodeData.StartEvent{event_definition: %EventDefinition.None{}},
              outgoing: ["F1"]
            },
            %FlowNode{
              id: "Recv1",
              type: :receive_task,
              type_data: %FlowNodeData.ReceiveTask{message_ref: "Msg_1"},
              incoming: ["F1"],
              outgoing: ["F2"]
            },
            %FlowNode{
              id: "E1",
              type: :end_event,
              type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
              incoming: ["F2"]
            }
          ],
          [
            %SequenceFlow{id: "F1", source_ref: "S1", target_ref: "Recv1"},
            %SequenceFlow{id: "F2", source_ref: "Recv1", target_ref: "E1"}
          ]
        )

      fnis = start_and_collect(definitions)
      recv_fni = Enum.find(fnis, &(&1.flow_node_id == "Recv1"))

      assert recv_fni.event_type == "message"
    end
  end
end
