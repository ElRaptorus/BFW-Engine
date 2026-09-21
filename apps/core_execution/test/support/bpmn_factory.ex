defmodule BfwEngine.Execution.TestSupport.BpmnFactory do
  @moduledoc """
  Helpers for building in-memory BPMN model structs for tests.
  Avoids XML parsing overhead and keeps tests focused on runtime logic.
  """

  alias BfwEngine.BPMN.Model.Definitions
  alias BfwEngine.BPMN.Model.EventDefinition
  alias BfwEngine.BPMN.Model.FlowNode
  alias BfwEngine.BPMN.Model.FlowNodeData
  alias BfwEngine.BPMN.Model.MessageDefinition
  alias BfwEngine.BPMN.Model.MultiInstance
  alias BfwEngine.BPMN.Model.Process, as: BpmnProcess
  alias BfwEngine.BPMN.Model.SequenceFlow
  alias BfwEngine.BPMN.Model.SignalDefinition

  @doc "Build a minimal Start → End process."
  def linear_start_end(process_id \\ "test-process") do
    start = %FlowNode{
      id: "Start_1",
      name: "Start",
      type: :start_event,
      type_data: %FlowNodeData.StartEvent{event_definition: %EventDefinition.None{}},
      outgoing: ["Flow_1"]
    }

    end_event = %FlowNode{
      id: "End_1",
      name: "Done",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
      incoming: ["Flow_1"]
    }

    flow = %SequenceFlow{id: "Flow_1", source_ref: "Start_1", target_ref: "End_1"}

    wrap_process(process_id, [start, end_event], [flow])
  end

  @doc "Build a Start → Task → End process."
  def linear_three_node(process_id \\ "test-process") do
    start = %FlowNode{
      id: "Start_1",
      type: :start_event,
      type_data: %FlowNodeData.StartEvent{event_definition: %EventDefinition.None{}},
      outgoing: ["Flow_1"]
    }

    task = %FlowNode{
      id: "Task_1",
      name: "Do Something",
      type: :task,
      type_data: %FlowNodeData.Task{},
      incoming: ["Flow_1"],
      outgoing: ["Flow_2"]
    }

    end_event = %FlowNode{
      id: "End_1",
      name: "Done",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
      incoming: ["Flow_2"]
    }

    flows = [
      %SequenceFlow{id: "Flow_1", source_ref: "Start_1", target_ref: "Task_1"},
      %SequenceFlow{id: "Flow_2", source_ref: "Task_1", target_ref: "End_1"}
    ]

    wrap_process(process_id, [start, task, end_event], flows)
  end

  @doc "Build a Start → UserTask → End process."
  def user_task_process(opts \\ []) do
    process_id = Keyword.get(opts, :process_id, "test-process")
    result_contract = Keyword.get(opts, :result_contract, nil)

    start = %FlowNode{
      id: "Start_1",
      type: :start_event,
      type_data: %FlowNodeData.StartEvent{event_definition: %EventDefinition.None{}},
      outgoing: ["Flow_1"]
    }

    user_task = %FlowNode{
      id: "UserTask_1",
      name: "Review",
      type: :user_task,
      type_data: %FlowNodeData.UserTask{
        form_schema: %{"fields" => []},
        result_contract: result_contract
      },
      incoming: ["Flow_1"],
      outgoing: ["Flow_2"]
    }

    end_event = %FlowNode{
      id: "End_1",
      name: "Done",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
      incoming: ["Flow_2"]
    }

    flows = [
      %SequenceFlow{id: "Flow_1", source_ref: "Start_1", target_ref: "UserTask_1"},
      %SequenceFlow{id: "Flow_2", source_ref: "UserTask_1", target_ref: "End_1"}
    ]

    wrap_process(process_id, [start, user_task, end_event], flows)
  end

  @doc "Build a Start → ManualTask(requireConfirmation) → End process."
  def manual_task_process(require_confirmation \\ true) do
    start = %FlowNode{
      id: "Start_1",
      type: :start_event,
      type_data: %FlowNodeData.StartEvent{event_definition: %EventDefinition.None{}},
      outgoing: ["Flow_1"]
    }

    manual_task = %FlowNode{
      id: "ManualTask_1",
      name: "Pack Order",
      type: :manual_task,
      type_data: %FlowNodeData.ManualTask{require_confirmation: require_confirmation},
      incoming: ["Flow_1"],
      outgoing: ["Flow_2"]
    }

    end_event = %FlowNode{
      id: "End_1",
      name: "Done",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
      incoming: ["Flow_2"]
    }

    flows = [
      %SequenceFlow{id: "Flow_1", source_ref: "Start_1", target_ref: "ManualTask_1"},
      %SequenceFlow{id: "Flow_2", source_ref: "ManualTask_1", target_ref: "End_1"}
    ]

    wrap_process("test-process", [start, manual_task, end_event], flows)
  end

  @doc "Build a process with an implicit split (non-gateway with 2 outgoing)."
  def implicit_split_process do
    start = %FlowNode{
      id: "Start_1",
      type: :start_event,
      type_data: %FlowNodeData.StartEvent{event_definition: %EventDefinition.None{}},
      outgoing: ["Flow_1"]
    }

    task = %FlowNode{
      id: "Task_1",
      type: :task,
      type_data: %FlowNodeData.Task{},
      incoming: ["Flow_1"],
      outgoing: ["Flow_2", "Flow_3"]
    }

    end1 = %FlowNode{
      id: "End_1",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
      incoming: ["Flow_2"]
    }

    end2 = %FlowNode{
      id: "End_2",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
      incoming: ["Flow_3"]
    }

    flows = [
      %SequenceFlow{id: "Flow_1", source_ref: "Start_1", target_ref: "Task_1"},
      %SequenceFlow{id: "Flow_2", source_ref: "Task_1", target_ref: "End_1"},
      %SequenceFlow{id: "Flow_3", source_ref: "Task_1", target_ref: "End_2"}
    ]

    wrap_process("test-process", [start, task, end1, end2], flows)
  end

  @doc "Build a process with a dead end (task with 0 outgoing flows)."
  def dead_end_process do
    start = %FlowNode{
      id: "Start_1",
      type: :start_event,
      type_data: %FlowNodeData.StartEvent{event_definition: %EventDefinition.None{}},
      outgoing: ["Flow_1"]
    }

    task = %FlowNode{
      id: "Task_1",
      type: :task,
      type_data: %FlowNodeData.Task{},
      incoming: ["Flow_1"],
      outgoing: []
    }

    flows = [
      %SequenceFlow{id: "Flow_1", source_ref: "Start_1", target_ref: "Task_1"}
    ]

    wrap_process("test-process", [start, task], flows)
  end

  @doc """
  Build a parallel fork where one branch has a dead end (→ fatal) and the
  other branch has a waiting UserTask.

  Start → ParallelGateway → [Task_Dead(0 outgoing), UserTask_Wait → End]

  When Task_Dead completes, it fatals (dead end). UserTask_Wait is still
  waiting. After the fix, fatal_all_fnis must also persist
  UserTask_Wait to fatal.
  """
  def parallel_fork_with_dead_end do
    start = %FlowNode{
      id: "Start_1",
      type: :start_event,
      type_data: %FlowNodeData.StartEvent{event_definition: %EventDefinition.None{}},
      outgoing: ["Flow_1"]
    }

    fork = %FlowNode{
      id: "Fork_1",
      name: "Fork",
      type: :parallel_gateway,
      type_data: %FlowNodeData.ParallelGateway{},
      incoming: ["Flow_1"],
      outgoing: ["Flow_A", "Flow_B"]
    }

    task_dead = %FlowNode{
      id: "Task_Dead",
      name: "Dead End Task",
      type: :task,
      type_data: %FlowNodeData.Task{},
      incoming: ["Flow_A"],
      outgoing: []
    }

    user_task_wait = %FlowNode{
      id: "UserTask_Wait",
      name: "Waiting User Task",
      type: :user_task,
      type_data: %FlowNodeData.UserTask{form_schema: %{"fields" => []}},
      incoming: ["Flow_B"],
      outgoing: ["Flow_C"]
    }

    end_event = %FlowNode{
      id: "End_1",
      name: "Done",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
      incoming: ["Flow_C"]
    }

    flows = [
      %SequenceFlow{id: "Flow_1", source_ref: "Start_1", target_ref: "Fork_1"},
      %SequenceFlow{id: "Flow_A", source_ref: "Fork_1", target_ref: "Task_Dead"},
      %SequenceFlow{id: "Flow_B", source_ref: "Fork_1", target_ref: "UserTask_Wait"},
      %SequenceFlow{id: "Flow_C", source_ref: "UserTask_Wait", target_ref: "End_1"}
    ]

    wrap_process("test-process", [start, fork, task_dead, user_task_wait, end_event], flows)
  end

  @doc "Build a process with multiple start events."
  def multi_start_process do
    start1 = %FlowNode{
      id: "Start_1",
      type: :start_event,
      type_data: %FlowNodeData.StartEvent{event_definition: %EventDefinition.None{}},
      outgoing: ["Flow_1"]
    }

    start2 = %FlowNode{
      id: "Start_2",
      type: :start_event,
      type_data: %FlowNodeData.StartEvent{event_definition: %EventDefinition.None{}},
      outgoing: ["Flow_2"]
    }

    end_event = %FlowNode{
      id: "End_1",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
      incoming: ["Flow_1", "Flow_2"]
    }

    flows = [
      %SequenceFlow{id: "Flow_1", source_ref: "Start_1", target_ref: "End_1"},
      %SequenceFlow{id: "Flow_2", source_ref: "Start_2", target_ref: "End_1"}
    ]

    wrap_process("test-process", [start1, start2, end_event], flows)
  end

  @doc "Build a Start → ServiceTask(implementation) → End process."
  def service_task_process(implementation \\ "echo") do
    start = %FlowNode{
      id: "Start_1",
      type: :start_event,
      type_data: %FlowNodeData.StartEvent{event_definition: %EventDefinition.None{}},
      outgoing: ["Flow_1"]
    }

    service_task = %FlowNode{
      id: "ServiceTask_1",
      name: "Service",
      type: :service_task,
      type_data: %FlowNodeData.ServiceTask{implementation: implementation},
      incoming: ["Flow_1"],
      outgoing: ["Flow_2"]
    }

    end_event = %FlowNode{
      id: "End_1",
      name: "Done",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
      incoming: ["Flow_2"]
    }

    flows = [
      %SequenceFlow{id: "Flow_1", source_ref: "Start_1", target_ref: "ServiceTask_1"},
      %SequenceFlow{id: "Flow_2", source_ref: "ServiceTask_1", target_ref: "End_1"}
    ]

    wrap_process("test-process", [start, service_task, end_event], flows)
  end

  @doc """
  Build a Start → ServiceTask(implementation=\"http\") → End process.

  Accepts HTTP extension fields via keyword options:
  `:http_url`, `:http_method`, `:http_body`, `:http_auth_header`,
  `:http_response_headers`, plus shared pipeline options
  `:in_mappings`, `:out_mappings`, `:payload_contract`, `:result_contract`.
  """
  def http_service_task_process(opts \\ []) do
    start = %FlowNode{
      id: "Start_1",
      type: :start_event,
      type_data: %FlowNodeData.StartEvent{event_definition: %EventDefinition.None{}},
      outgoing: ["Flow_1"]
    }

    service_task = %FlowNode{
      id: "ServiceTask_1",
      name: "HTTP Service",
      type: :service_task,
      type_data: %FlowNodeData.ServiceTask{
        implementation: "http",
        http_url: Keyword.get(opts, :http_url, "http://test.local/api"),
        http_method: Keyword.get(opts, :http_method, nil),
        http_body: Keyword.get(opts, :http_body, nil),
        http_auth_header: Keyword.get(opts, :http_auth_header, nil),
        http_response_headers: Keyword.get(opts, :http_response_headers, nil),
        in_mappings: Keyword.get(opts, :in_mappings, []),
        out_mappings: Keyword.get(opts, :out_mappings, []),
        payload_contract: Keyword.get(opts, :payload_contract, nil),
        result_contract: Keyword.get(opts, :result_contract, nil)
      },
      incoming: ["Flow_1"],
      outgoing: ["Flow_2"]
    }

    end_event = %FlowNode{
      id: "End_1",
      name: "Done",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
      incoming: ["Flow_2"]
    }

    flows = [
      %SequenceFlow{id: "Flow_1", source_ref: "Start_1", target_ref: "ServiceTask_1"},
      %SequenceFlow{id: "Flow_2", source_ref: "ServiceTask_1", target_ref: "End_1"}
    ]

    wrap_process("test-process", [start, service_task, end_event], flows)
  end

  @doc "Build a Start → ScriptTask → End process."
  def script_task_process(opts \\ []) do
    script = Keyword.get(opts, :script, nil)
    script_ref = Keyword.get(opts, :script_ref, nil)
    script_format = Keyword.get(opts, :script_format, nil)
    in_mappings = Keyword.get(opts, :in_mappings, [])
    out_mappings = Keyword.get(opts, :out_mappings, [])
    payload_contract = Keyword.get(opts, :payload_contract, nil)
    result_contract = Keyword.get(opts, :result_contract, nil)

    start = %FlowNode{
      id: "Start_1",
      type: :start_event,
      type_data: %FlowNodeData.StartEvent{event_definition: %EventDefinition.None{}},
      outgoing: ["Flow_1"]
    }

    script_task = %FlowNode{
      id: "ScriptTask_1",
      name: "Script",
      type: :script_task,
      type_data: %FlowNodeData.ScriptTask{
        script: script,
        script_ref: script_ref,
        script_format: script_format,
        in_mappings: in_mappings,
        out_mappings: out_mappings,
        payload_contract: payload_contract,
        result_contract: result_contract
      },
      incoming: ["Flow_1"],
      outgoing: ["Flow_2"]
    }

    end_event = %FlowNode{
      id: "End_1",
      name: "Done",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
      incoming: ["Flow_2"]
    }

    flows = [
      %SequenceFlow{id: "Flow_1", source_ref: "Start_1", target_ref: "ScriptTask_1"},
      %SequenceFlow{id: "Flow_2", source_ref: "ScriptTask_1", target_ref: "End_1"}
    ]

    wrap_process("test-process", [start, script_task, end_event], flows)
  end

  @doc "Build a Start → BusinessRuleTask → End process."
  def business_rule_task_process(opts \\ []) do
    implementation = Keyword.get(opts, :implementation, "feel")
    script = Keyword.get(opts, :script, nil)
    rule_ref = Keyword.get(opts, :rule_ref, nil)
    decision_ref = Keyword.get(opts, :decision_ref, nil)
    result_variable = Keyword.get(opts, :result_variable, nil)
    trace_unmatched_rules = Keyword.get(opts, :trace_unmatched_rules, false)
    in_mappings = Keyword.get(opts, :in_mappings, [])
    out_mappings = Keyword.get(opts, :out_mappings, [])
    payload_contract = Keyword.get(opts, :payload_contract, nil)
    result_contract = Keyword.get(opts, :result_contract, nil)

    start = %FlowNode{
      id: "Start_1",
      type: :start_event,
      type_data: %FlowNodeData.StartEvent{event_definition: %EventDefinition.None{}},
      outgoing: ["Flow_1"]
    }

    business_rule_task = %FlowNode{
      id: "BRT_1",
      name: "Business Rule",
      type: :business_rule_task,
      type_data: %FlowNodeData.BusinessRuleTask{
        implementation: implementation,
        script: script,
        rule_ref: rule_ref,
        decision_ref: decision_ref,
        result_variable: result_variable,
        trace_unmatched_rules: trace_unmatched_rules,
        in_mappings: in_mappings,
        out_mappings: out_mappings,
        payload_contract: payload_contract,
        result_contract: result_contract
      },
      incoming: ["Flow_1"],
      outgoing: ["Flow_2"]
    }

    end_event = %FlowNode{
      id: "End_1",
      name: "Done",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
      incoming: ["Flow_2"]
    }

    flows = [
      %SequenceFlow{id: "Flow_1", source_ref: "Start_1", target_ref: "BRT_1"},
      %SequenceFlow{id: "Flow_2", source_ref: "BRT_1", target_ref: "End_1"}
    ]

    wrap_process("test-process", [start, business_rule_task, end_event], flows)
  end

  @doc "Build a process with an unsupported element type."
  def unsupported_element_process do
    start = %FlowNode{
      id: "Start_1",
      type: :start_event,
      type_data: %FlowNodeData.StartEvent{event_definition: %EventDefinition.None{}},
      outgoing: ["Flow_1"]
    }

    service_task = %FlowNode{
      id: "Service_1",
      type: :service_task,
      type_data: %FlowNodeData.ServiceTask{},
      incoming: ["Flow_1"],
      outgoing: ["Flow_2"]
    }

    end_event = %FlowNode{
      id: "End_1",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
      incoming: ["Flow_2"]
    }

    flows = [
      %SequenceFlow{id: "Flow_1", source_ref: "Start_1", target_ref: "Service_1"},
      %SequenceFlow{id: "Flow_2", source_ref: "Service_1", target_ref: "End_1"}
    ]

    wrap_process("test-process", [start, service_task, end_event], flows)
  end

  @doc """
  Build a Start → XOR Split → EndA / EndB process.

  Two conditional outgoing flows from the XOR gateway. The first
  evaluates `token.amount > 100`, the second `token.amount <= 100`.
  """
  def xor_split_process do
    start = %FlowNode{
      id: "Start_1",
      type: :start_event,
      type_data: %FlowNodeData.StartEvent{event_definition: %EventDefinition.None{}},
      outgoing: ["Flow_1"]
    }

    gateway = %FlowNode{
      id: "XOR_1",
      type: :exclusive_gateway,
      type_data: %FlowNodeData.ExclusiveGateway{},
      incoming: ["Flow_1"],
      outgoing: ["Flow_A", "Flow_B"]
    }

    end_a = %FlowNode{
      id: "End_A",
      name: "High",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
      incoming: ["Flow_A"]
    }

    end_b = %FlowNode{
      id: "End_B",
      name: "Low",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
      incoming: ["Flow_B"]
    }

    flows = [
      %SequenceFlow{id: "Flow_1", source_ref: "Start_1", target_ref: "XOR_1"},
      %SequenceFlow{
        id: "Flow_A",
        source_ref: "XOR_1",
        target_ref: "End_A",
        condition_expression: "token.amount > 100"
      },
      %SequenceFlow{
        id: "Flow_B",
        source_ref: "XOR_1",
        target_ref: "End_B",
        condition_expression: "token.amount <= 100"
      }
    ]

    wrap_process("test-process", [start, gateway, end_a, end_b], flows)
  end

  @doc """
  Build a Start → XOR Split → EndA / EndDefault process.

  One conditional flow (`token.amount > 1000`) and one default flow.
  """
  def xor_split_with_default_process do
    start = %FlowNode{
      id: "Start_1",
      type: :start_event,
      type_data: %FlowNodeData.StartEvent{event_definition: %EventDefinition.None{}},
      outgoing: ["Flow_1"]
    }

    gateway = %FlowNode{
      id: "XOR_1",
      type: :exclusive_gateway,
      type_data: %FlowNodeData.ExclusiveGateway{default_flow_ref: "Flow_Default"},
      incoming: ["Flow_1"],
      outgoing: ["Flow_A", "Flow_Default"]
    }

    end_a = %FlowNode{
      id: "End_A",
      name: "Premium",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
      incoming: ["Flow_A"]
    }

    end_default = %FlowNode{
      id: "End_Default",
      name: "Standard",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
      incoming: ["Flow_Default"]
    }

    flows = [
      %SequenceFlow{id: "Flow_1", source_ref: "Start_1", target_ref: "XOR_1"},
      %SequenceFlow{
        id: "Flow_A",
        source_ref: "XOR_1",
        target_ref: "End_A",
        condition_expression: "token.amount > 1000"
      },
      %SequenceFlow{
        id: "Flow_Default",
        source_ref: "XOR_1",
        target_ref: "End_Default",
        is_default: true
      }
    ]

    wrap_process("test-process", [start, gateway, end_a, end_default], flows)
  end

  @doc """
  Build a Start → XOR Split (ambiguous) → EndA / EndB process.

  Both conditions are always true for amount > 10: `token.amount > 10`
  and `token.amount > 5`.
  """
  def xor_split_ambiguous_process do
    start = %FlowNode{
      id: "Start_1",
      type: :start_event,
      type_data: %FlowNodeData.StartEvent{event_definition: %EventDefinition.None{}},
      outgoing: ["Flow_1"]
    }

    gateway = %FlowNode{
      id: "XOR_1",
      type: :exclusive_gateway,
      type_data: %FlowNodeData.ExclusiveGateway{},
      incoming: ["Flow_1"],
      outgoing: ["Flow_A", "Flow_B"]
    }

    end_a = %FlowNode{
      id: "End_A",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
      incoming: ["Flow_A"]
    }

    end_b = %FlowNode{
      id: "End_B",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
      incoming: ["Flow_B"]
    }

    flows = [
      %SequenceFlow{id: "Flow_1", source_ref: "Start_1", target_ref: "XOR_1"},
      %SequenceFlow{
        id: "Flow_A",
        source_ref: "XOR_1",
        target_ref: "End_A",
        condition_expression: "token.amount > 10"
      },
      %SequenceFlow{
        id: "Flow_B",
        source_ref: "XOR_1",
        target_ref: "End_B",
        condition_expression: "token.amount > 5"
      }
    ]

    wrap_process("test-process", [start, gateway, end_a, end_b], flows)
  end

  @doc """
  Build a Start → XOR Split (no match, no default) → EndA process.

  Condition `token.amount > 99999` will never be true for normal payloads.
  """
  def xor_split_no_match_process do
    start = %FlowNode{
      id: "Start_1",
      type: :start_event,
      type_data: %FlowNodeData.StartEvent{event_definition: %EventDefinition.None{}},
      outgoing: ["Flow_1"]
    }

    gateway = %FlowNode{
      id: "XOR_1",
      type: :exclusive_gateway,
      type_data: %FlowNodeData.ExclusiveGateway{},
      incoming: ["Flow_1"],
      outgoing: ["Flow_A"]
    }

    end_a = %FlowNode{
      id: "End_A",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
      incoming: ["Flow_A"]
    }

    flows = [
      %SequenceFlow{id: "Flow_1", source_ref: "Start_1", target_ref: "XOR_1"},
      %SequenceFlow{
        id: "Flow_A",
        source_ref: "XOR_1",
        target_ref: "End_A",
        condition_expression: "token.amount > 99999"
      }
    ]

    wrap_process("test-process", [start, gateway, end_a], flows)
  end

  @doc """
  Build a Start → TaskA / TaskB → XOR Join → End process.

  Uses a simple Start → XOR join topology where the join has two
  incoming and one outgoing.
  """
  def xor_join_process do
    start = %FlowNode{
      id: "Start_1",
      type: :start_event,
      type_data: %FlowNodeData.StartEvent{event_definition: %EventDefinition.None{}},
      outgoing: ["Flow_1"]
    }

    task = %FlowNode{
      id: "Task_1",
      type: :task,
      type_data: %FlowNodeData.Task{},
      incoming: ["Flow_1"],
      outgoing: ["Flow_2"]
    }

    xor_join = %FlowNode{
      id: "XOR_Join",
      type: :exclusive_gateway,
      type_data: %FlowNodeData.ExclusiveGateway{},
      incoming: ["Flow_2", "Flow_3"],
      outgoing: ["Flow_Out"]
    }

    end_event = %FlowNode{
      id: "End_1",
      name: "Done",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
      incoming: ["Flow_Out"]
    }

    flows = [
      %SequenceFlow{id: "Flow_1", source_ref: "Start_1", target_ref: "Task_1"},
      %SequenceFlow{id: "Flow_2", source_ref: "Task_1", target_ref: "XOR_Join"},
      %SequenceFlow{id: "Flow_3", source_ref: "Task_1", target_ref: "XOR_Join"},
      %SequenceFlow{id: "Flow_Out", source_ref: "XOR_Join", target_ref: "End_1"}
    ]

    wrap_process("test-process", [start, task, xor_join, end_event], flows)
  end

  @doc """
  Build a Start → CallActivity → End process.

  The called element defaults to "child-process".
  """
  def call_activity_process(opts \\ []) do
    called_element = Keyword.get(opts, :called_element, "child-process")
    start_event_id = Keyword.get(opts, :start_event_id)
    called_process_version = Keyword.get(opts, :called_process_version)
    in_mappings = Keyword.get(opts, :in_mappings, [])
    out_mappings = Keyword.get(opts, :out_mappings, [])

    start = %FlowNode{
      id: "Start_1",
      type: :start_event,
      type_data: %FlowNodeData.StartEvent{event_definition: %EventDefinition.None{}},
      outgoing: ["Flow_1"]
    }

    ca = %FlowNode{
      id: "CA_1",
      name: "Call Child",
      type: :call_activity,
      type_data: %FlowNodeData.CallActivity{
        called_element: called_element,
        start_event_id: start_event_id,
        called_process_version: called_process_version,
        in_mappings: in_mappings,
        out_mappings: out_mappings
      },
      incoming: ["Flow_1"],
      outgoing: ["Flow_2"],
      boundary_event_refs: Keyword.get(opts, :boundary_refs, [])
    }

    end_event = %FlowNode{
      id: "End_1",
      name: "Done",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
      incoming: ["Flow_2"]
    }

    extra_nodes = Keyword.get(opts, :extra_nodes, [])
    extra_flows = Keyword.get(opts, :extra_flows, [])

    flows = [
      %SequenceFlow{id: "Flow_1", source_ref: "Start_1", target_ref: "CA_1"},
      %SequenceFlow{id: "Flow_2", source_ref: "CA_1", target_ref: "End_1"}
    ]

    wrap_process("test-process", [start, ca, end_event] ++ extra_nodes, flows ++ extra_flows)
  end

  @doc """
  Build a Start → CallActivity (with error boundary) → End process.

  The error boundary catches errors matching `error_code` and routes to End_Error.
  """
  def call_activity_with_error_boundary(opts \\ []) do
    error_code = Keyword.get(opts, :error_code, nil)
    error_message = Keyword.get(opts, :error_message, nil)

    boundary = %FlowNode{
      id: "BE_1",
      type: :boundary_event,
      type_data: %FlowNodeData.BoundaryEvent{
        attached_to_ref: "CA_1",
        cancel_activity: true,
        event_definition: %EventDefinition.Error{
          error_code: error_code,
          error_message: error_message
        }
      },
      outgoing: ["Flow_BE"]
    }

    end_error = %FlowNode{
      id: "End_Error",
      name: "Error Path",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
      incoming: ["Flow_BE"]
    }

    flow_be = %SequenceFlow{id: "Flow_BE", source_ref: "BE_1", target_ref: "End_Error"}

    call_activity_process(
      Keyword.merge(opts,
        boundary_refs: ["BE_1"],
        extra_nodes: [boundary, end_error],
        extra_flows: [flow_be]
      )
    )
  end

  @doc "Build a process with two untyped Start Events (Start_A → Task_A → End_A, Start_B → Task_B → End_B)."
  def multi_start_process(process_id) do
    start_a = %FlowNode{
      id: "Start_A",
      name: "Start A",
      type: :start_event,
      type_data: %FlowNodeData.StartEvent{event_definition: %EventDefinition.None{}},
      outgoing: ["Flow_A1"]
    }

    task_a = %FlowNode{
      id: "Task_A",
      name: "Path A Task",
      type: :task,
      type_data: %FlowNodeData.Task{},
      incoming: ["Flow_A1"],
      outgoing: ["Flow_A2"]
    }

    end_a = %FlowNode{
      id: "End_A",
      name: "End A",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
      incoming: ["Flow_A2"]
    }

    start_b = %FlowNode{
      id: "Start_B",
      name: "Start B",
      type: :start_event,
      type_data: %FlowNodeData.StartEvent{event_definition: %EventDefinition.None{}},
      outgoing: ["Flow_B1"]
    }

    task_b = %FlowNode{
      id: "Task_B",
      name: "Path B Task",
      type: :task,
      type_data: %FlowNodeData.Task{},
      incoming: ["Flow_B1"],
      outgoing: ["Flow_B2"]
    }

    end_b = %FlowNode{
      id: "End_B",
      name: "End B",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
      incoming: ["Flow_B2"]
    }

    flows = [
      %SequenceFlow{id: "Flow_A1", source_ref: "Start_A", target_ref: "Task_A"},
      %SequenceFlow{id: "Flow_A2", source_ref: "Task_A", target_ref: "End_A"},
      %SequenceFlow{id: "Flow_B1", source_ref: "Start_B", target_ref: "Task_B"},
      %SequenceFlow{id: "Flow_B2", source_ref: "Task_B", target_ref: "End_B"}
    ]

    wrap_process(process_id, [start_a, task_a, end_a, start_b, task_b, end_b], flows)
  end

  @doc """
  Build a Start → TimerCatchEvent(duration) → End process.

  The timer catch event uses a timer event definition with either
  `time_date` or `time_duration` set.
  """
  def timer_catch_event_process(opts \\ []) do
    process_id = Keyword.get(opts, :process_id, "test-process")
    time_date = Keyword.get(opts, :time_date, nil)
    time_duration = Keyword.get(opts, :time_duration, nil)
    time_cycle = Keyword.get(opts, :time_cycle, nil)

    start = %FlowNode{
      id: "Start_1",
      type: :start_event,
      type_data: %FlowNodeData.StartEvent{event_definition: %EventDefinition.None{}},
      outgoing: ["Flow_1"]
    }

    timer_catch = %FlowNode{
      id: "TimerCatch_1",
      name: "Wait for Timer",
      type: :intermediate_catch_event,
      type_data: %FlowNodeData.IntermediateCatchEvent{
        event_definition: %EventDefinition.Timer{
          time_date: time_date,
          time_duration: time_duration,
          time_cycle: time_cycle
        }
      },
      incoming: ["Flow_1"],
      outgoing: ["Flow_2"]
    }

    end_event = %FlowNode{
      id: "End_1",
      name: "Done",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
      incoming: ["Flow_2"]
    }

    flows = [
      %SequenceFlow{id: "Flow_1", source_ref: "Start_1", target_ref: "TimerCatch_1"},
      %SequenceFlow{id: "Flow_2", source_ref: "TimerCatch_1", target_ref: "End_1"}
    ]

    wrap_process(process_id, [start, timer_catch, end_event], flows)
  end

  @doc """
  Build a Start → UserTask (with timer boundary event) → End process.

  The timer boundary event is attached to the UserTask, with the
  specified timer type (`:time_duration`, `:time_date`, or `:time_cycle`)
  and `cancel_activity` flag.
  """
  def user_task_with_timer_boundary(opts \\ []) do
    process_id = Keyword.get(opts, :process_id, "test-process")
    cancel_activity = Keyword.get(opts, :cancel_activity, true)
    time_duration = Keyword.get(opts, :time_duration, nil)
    time_date = Keyword.get(opts, :time_date, nil)
    time_cycle = Keyword.get(opts, :time_cycle, nil)

    start = %FlowNode{
      id: "Start_1",
      type: :start_event,
      type_data: %FlowNodeData.StartEvent{event_definition: %EventDefinition.None{}},
      outgoing: ["Flow_1"]
    }

    user_task = %FlowNode{
      id: "UserTask_1",
      name: "Do Work",
      type: :user_task,
      type_data: %FlowNodeData.UserTask{form_schema: %{"fields" => []}},
      incoming: ["Flow_1"],
      outgoing: ["Flow_2"],
      boundary_event_refs: ["TimerBE_1"]
    }

    timer_boundary = %FlowNode{
      id: "TimerBE_1",
      name: "Timer Boundary",
      type: :boundary_event,
      type_data: %FlowNodeData.BoundaryEvent{
        attached_to_ref: "UserTask_1",
        cancel_activity: cancel_activity,
        event_definition: %EventDefinition.Timer{
          time_date: time_date,
          time_duration: time_duration,
          time_cycle: time_cycle
        }
      },
      outgoing: ["Flow_BE"]
    }

    end_normal = %FlowNode{
      id: "End_Normal",
      name: "Normal End",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
      incoming: ["Flow_2"]
    }

    end_timeout = %FlowNode{
      id: "End_Timeout",
      name: "Timeout End",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
      incoming: ["Flow_BE"]
    }

    flows = [
      %SequenceFlow{id: "Flow_1", source_ref: "Start_1", target_ref: "UserTask_1"},
      %SequenceFlow{id: "Flow_2", source_ref: "UserTask_1", target_ref: "End_Normal"},
      %SequenceFlow{id: "Flow_BE", source_ref: "TimerBE_1", target_ref: "End_Timeout"}
    ]

    wrap_process(
      process_id,
      [start, user_task, timer_boundary, end_normal, end_timeout],
      flows
    )
  end

  @doc """
  Build a Start → UserTask + non-interrupting Message boundary → End process.
  """
  def user_task_with_message_boundary(opts \\ []) do
    process_id = Keyword.get(opts, :process_id, "test-process")
    cancel_activity = Keyword.get(opts, :cancel_activity, false)
    message_id = Keyword.get(opts, :message_id, "Message_1")
    message_name = Keyword.get(opts, :message_name, "boundary-message")

    start = %FlowNode{
      id: "Start_1",
      type: :start_event,
      type_data: %FlowNodeData.StartEvent{event_definition: %EventDefinition.None{}},
      outgoing: ["Flow_1"]
    }

    user_task = %FlowNode{
      id: "UserTask_1",
      name: "Do Work",
      type: :user_task,
      type_data: %FlowNodeData.UserTask{form_schema: %{"fields" => []}},
      incoming: ["Flow_1"],
      outgoing: ["Flow_2"],
      boundary_event_refs: ["MessageBE_1"]
    }

    message_boundary = %FlowNode{
      id: "MessageBE_1",
      name: "Message Boundary",
      type: :boundary_event,
      type_data: %FlowNodeData.BoundaryEvent{
        attached_to_ref: "UserTask_1",
        cancel_activity: cancel_activity,
        event_definition: %EventDefinition.Message{message_ref: message_id}
      },
      outgoing: ["Flow_BE"]
    }

    end_normal = %FlowNode{
      id: "End_Normal",
      name: "Normal End",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
      incoming: ["Flow_2"]
    }

    end_boundary = %FlowNode{
      id: "End_Boundary",
      name: "Boundary End",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
      incoming: ["Flow_BE"]
    }

    flows = [
      %SequenceFlow{id: "Flow_1", source_ref: "Start_1", target_ref: "UserTask_1"},
      %SequenceFlow{id: "Flow_2", source_ref: "UserTask_1", target_ref: "End_Normal"},
      %SequenceFlow{id: "Flow_BE", source_ref: "MessageBE_1", target_ref: "End_Boundary"}
    ]

    wrap_process_with_messages(
      process_id,
      [start, user_task, message_boundary, end_normal, end_boundary],
      flows,
      [%MessageDefinition{id: message_id, name: message_name}]
    )
  end

  @doc """
  Build a Start → Message Throw → End process with an optional
  `correlation_retrieval_expression` on the throw event definition.
  """
  def message_throw_process(opts \\ []) do
    process_id = Keyword.get(opts, :process_id, "test-process")
    message_id = Keyword.get(opts, :message_id, "Message_1")
    message_name = Keyword.get(opts, :message_name, "thrown-message")

    correlation_retrieval_expression =
      Keyword.get(opts, :correlation_retrieval_expression)

    start = %FlowNode{
      id: "Start_1",
      type: :start_event,
      type_data: %FlowNodeData.StartEvent{event_definition: %EventDefinition.None{}},
      outgoing: ["Flow_1"]
    }

    throw_event = %FlowNode{
      id: "Throw_1",
      name: "Throw Message",
      type: :intermediate_throw_event,
      type_data: %FlowNodeData.IntermediateThrowEvent{
        event_definition: %EventDefinition.Message{
          message_ref: message_id,
          correlation_retrieval_expression: correlation_retrieval_expression
        }
      },
      incoming: ["Flow_1"],
      outgoing: ["Flow_2"]
    }

    end_event = %FlowNode{
      id: "End_1",
      name: "Done",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
      incoming: ["Flow_2"]
    }

    flows = [
      %SequenceFlow{id: "Flow_1", source_ref: "Start_1", target_ref: "Throw_1"},
      %SequenceFlow{id: "Flow_2", source_ref: "Throw_1", target_ref: "End_1"}
    ]

    wrap_process_with_messages(
      process_id,
      [start, throw_event, end_event],
      flows,
      [%MessageDefinition{id: message_id, name: message_name}]
    )
  end

  @doc """
  Build a Start → Task (auto-completing) + TimerBE_1 → End process.

  The plain Task handler completes immediately after `handle_enter`,
  which triggers boundary cleanup. Useful for testing that boundary
  FNIs are cancelled when the host activity finishes normally.
  """
  def task_with_timer_boundary(opts \\ []) do
    process_id = Keyword.get(opts, :process_id, "test-process")
    cancel_activity = Keyword.get(opts, :cancel_activity, true)
    time_duration = Keyword.get(opts, :time_duration, nil)
    time_date = Keyword.get(opts, :time_date, nil)
    time_cycle = Keyword.get(opts, :time_cycle, nil)

    start = %FlowNode{
      id: "Start_1",
      type: :start_event,
      type_data: %FlowNodeData.StartEvent{event_definition: %EventDefinition.None{}},
      outgoing: ["Flow_1"]
    }

    task = %FlowNode{
      id: "Task_1",
      name: "Auto Work",
      type: :task,
      type_data: %FlowNodeData.Task{},
      incoming: ["Flow_1"],
      outgoing: ["Flow_2"],
      boundary_event_refs: ["TimerBE_1"]
    }

    timer_boundary = %FlowNode{
      id: "TimerBE_1",
      name: "Timer Boundary",
      type: :boundary_event,
      type_data: %FlowNodeData.BoundaryEvent{
        attached_to_ref: "Task_1",
        cancel_activity: cancel_activity,
        event_definition: %EventDefinition.Timer{
          time_date: time_date,
          time_duration: time_duration,
          time_cycle: time_cycle
        }
      },
      outgoing: ["Flow_BE"]
    }

    end_normal = %FlowNode{
      id: "End_Normal",
      name: "Normal End",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
      incoming: ["Flow_2"]
    }

    end_timeout = %FlowNode{
      id: "End_Timeout",
      name: "Timeout End",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
      incoming: ["Flow_BE"]
    }

    flows = [
      %SequenceFlow{id: "Flow_1", source_ref: "Start_1", target_ref: "Task_1"},
      %SequenceFlow{id: "Flow_2", source_ref: "Task_1", target_ref: "End_Normal"},
      %SequenceFlow{id: "Flow_BE", source_ref: "TimerBE_1", target_ref: "End_Timeout"}
    ]

    wrap_process(
      process_id,
      [start, task, timer_boundary, end_normal, end_timeout],
      flows
    )
  end

  @doc """
  Build a process with a Timer Start Event → End.
  The timer start event uses the provided timer spec.
  """
  def timer_start_event_process(opts \\ []) do
    process_id = Keyword.get(opts, :process_id, "test-process")
    time_date = Keyword.get(opts, :time_date, nil)
    time_duration = Keyword.get(opts, :time_duration, nil)
    time_cycle = Keyword.get(opts, :time_cycle, nil)

    timer_start = %FlowNode{
      id: "TimerStart_1",
      name: "Timer Start",
      type: :start_event,
      type_data: %FlowNodeData.StartEvent{
        event_definition: %EventDefinition.Timer{
          time_date: time_date,
          time_duration: time_duration,
          time_cycle: time_cycle
        }
      },
      outgoing: ["Flow_1"]
    }

    end_event = %FlowNode{
      id: "End_1",
      name: "Done",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
      incoming: ["Flow_1"]
    }

    flow = %SequenceFlow{id: "Flow_1", source_ref: "TimerStart_1", target_ref: "End_1"}

    wrap_process(process_id, [timer_start, end_event], [flow])
  end

  @doc """
  Build a Start → ServiceTask (unknown impl, will fatal) + TimerBE_1 → End process.

  The service task has an unresolvable implementation, causing `handle_enter`
  to fail. Since the only boundary is a timer boundary (not an error boundary),
  the error is NOT caught — the host FNI goes fatal and the PI transitions to
  fatal, but the boundary FNI should be cancelled via `cancel_boundary_fnis_for_host`.
  """
  def service_task_fatal_with_timer_boundary(opts \\ []) do
    process_id = Keyword.get(opts, :process_id, "test-process")
    cancel_activity = Keyword.get(opts, :cancel_activity, true)
    time_duration = Keyword.get(opts, :time_duration, nil)
    time_date = Keyword.get(opts, :time_date, nil)
    time_cycle = Keyword.get(opts, :time_cycle, nil)

    start = %FlowNode{
      id: "Start_1",
      type: :start_event,
      type_data: %FlowNodeData.StartEvent{event_definition: %EventDefinition.None{}},
      outgoing: ["Flow_1"]
    }

    service_task = %FlowNode{
      id: "ServiceTask_1",
      name: "Failing Service",
      type: :service_task,
      type_data: %FlowNodeData.ServiceTask{implementation: "nonexistent-handler-xyz"},
      incoming: ["Flow_1"],
      outgoing: ["Flow_2"],
      boundary_event_refs: ["TimerBE_1"]
    }

    timer_boundary = %FlowNode{
      id: "TimerBE_1",
      name: "Timer Boundary",
      type: :boundary_event,
      type_data: %FlowNodeData.BoundaryEvent{
        attached_to_ref: "ServiceTask_1",
        cancel_activity: cancel_activity,
        event_definition: %EventDefinition.Timer{
          time_date: time_date,
          time_duration: time_duration,
          time_cycle: time_cycle
        }
      },
      outgoing: ["Flow_BE"]
    }

    end_normal = %FlowNode{
      id: "End_Normal",
      name: "Normal End",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
      incoming: ["Flow_2"]
    }

    end_timeout = %FlowNode{
      id: "End_Timeout",
      name: "Timeout End",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
      incoming: ["Flow_BE"]
    }

    flows = [
      %SequenceFlow{id: "Flow_1", source_ref: "Start_1", target_ref: "ServiceTask_1"},
      %SequenceFlow{id: "Flow_2", source_ref: "ServiceTask_1", target_ref: "End_Normal"},
      %SequenceFlow{id: "Flow_BE", source_ref: "TimerBE_1", target_ref: "End_Timeout"}
    ]

    wrap_process(
      process_id,
      [start, service_task, timer_boundary, end_normal, end_timeout],
      flows
    )
  end

  @doc """
  Build a Start → UserTask (with two interrupting timer boundaries) → End process.

  Both boundaries have the same timer spec so they fire near-simultaneously.
  The first to be processed by the PI wins; the second is stale-discarded.
  """
  def user_task_with_dual_timer_boundaries(opts \\ []) do
    process_id = Keyword.get(opts, :process_id, "test-process")
    time_duration = Keyword.get(opts, :time_duration, "PT0S")

    start = %FlowNode{
      id: "Start_1",
      type: :start_event,
      type_data: %FlowNodeData.StartEvent{event_definition: %EventDefinition.None{}},
      outgoing: ["Flow_1"]
    }

    user_task = %FlowNode{
      id: "UserTask_1",
      name: "Do Work",
      type: :user_task,
      type_data: %FlowNodeData.UserTask{form_schema: %{"fields" => []}},
      incoming: ["Flow_1"],
      outgoing: ["Flow_2"],
      boundary_event_refs: ["TimerBE_A", "TimerBE_B"]
    }

    timer_boundary_a = %FlowNode{
      id: "TimerBE_A",
      name: "Timer Boundary A",
      type: :boundary_event,
      type_data: %FlowNodeData.BoundaryEvent{
        attached_to_ref: "UserTask_1",
        cancel_activity: true,
        event_definition: %EventDefinition.Timer{time_duration: time_duration}
      },
      outgoing: ["Flow_BE_A"]
    }

    timer_boundary_b = %FlowNode{
      id: "TimerBE_B",
      name: "Timer Boundary B",
      type: :boundary_event,
      type_data: %FlowNodeData.BoundaryEvent{
        attached_to_ref: "UserTask_1",
        cancel_activity: true,
        event_definition: %EventDefinition.Timer{time_duration: time_duration}
      },
      outgoing: ["Flow_BE_B"]
    }

    end_normal = %FlowNode{
      id: "End_Normal",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
      incoming: ["Flow_2"]
    }

    end_timeout_a = %FlowNode{
      id: "End_Timeout_A",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
      incoming: ["Flow_BE_A"]
    }

    end_timeout_b = %FlowNode{
      id: "End_Timeout_B",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
      incoming: ["Flow_BE_B"]
    }

    flows = [
      %SequenceFlow{id: "Flow_1", source_ref: "Start_1", target_ref: "UserTask_1"},
      %SequenceFlow{id: "Flow_2", source_ref: "UserTask_1", target_ref: "End_Normal"},
      %SequenceFlow{id: "Flow_BE_A", source_ref: "TimerBE_A", target_ref: "End_Timeout_A"},
      %SequenceFlow{id: "Flow_BE_B", source_ref: "TimerBE_B", target_ref: "End_Timeout_B"}
    ]

    wrap_process(
      process_id,
      [
        start,
        user_task,
        timer_boundary_a,
        timer_boundary_b,
        end_normal,
        end_timeout_a,
        end_timeout_b
      ],
      flows
    )
  end

  @doc """
  Build a Start → UserTask (with one non-interrupting + one interrupting timer boundary) → End.

  The non-interrupting boundary fires first (spawns parallel branch, host continues).
  The interrupting boundary fires second (interrupts host, cancels remaining boundaries).
  """
  def user_task_with_mixed_timer_boundaries(opts \\ []) do
    process_id = Keyword.get(opts, :process_id, "test-process")
    non_interrupting_duration = Keyword.get(opts, :non_interrupting_duration, "PT0S")
    interrupting_duration = Keyword.get(opts, :interrupting_duration, "PT0S")

    start = %FlowNode{
      id: "Start_1",
      type: :start_event,
      type_data: %FlowNodeData.StartEvent{event_definition: %EventDefinition.None{}},
      outgoing: ["Flow_1"]
    }

    user_task = %FlowNode{
      id: "UserTask_1",
      name: "Do Work",
      type: :user_task,
      type_data: %FlowNodeData.UserTask{form_schema: %{"fields" => []}},
      incoming: ["Flow_1"],
      outgoing: ["Flow_2"],
      boundary_event_refs: ["TimerBE_NonInt", "TimerBE_Int"]
    }

    timer_non_interrupting = %FlowNode{
      id: "TimerBE_NonInt",
      name: "Non-Interrupting Timer",
      type: :boundary_event,
      type_data: %FlowNodeData.BoundaryEvent{
        attached_to_ref: "UserTask_1",
        cancel_activity: false,
        event_definition: %EventDefinition.Timer{time_duration: non_interrupting_duration}
      },
      outgoing: ["Flow_BE_NonInt"]
    }

    timer_interrupting = %FlowNode{
      id: "TimerBE_Int",
      name: "Interrupting Timer",
      type: :boundary_event,
      type_data: %FlowNodeData.BoundaryEvent{
        attached_to_ref: "UserTask_1",
        cancel_activity: true,
        event_definition: %EventDefinition.Timer{time_duration: interrupting_duration}
      },
      outgoing: ["Flow_BE_Int"]
    }

    end_normal = %FlowNode{
      id: "End_Normal",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
      incoming: ["Flow_2"]
    }

    end_non_int = %FlowNode{
      id: "End_NonInt",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
      incoming: ["Flow_BE_NonInt"]
    }

    end_int = %FlowNode{
      id: "End_Int",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
      incoming: ["Flow_BE_Int"]
    }

    flows = [
      %SequenceFlow{id: "Flow_1", source_ref: "Start_1", target_ref: "UserTask_1"},
      %SequenceFlow{id: "Flow_2", source_ref: "UserTask_1", target_ref: "End_Normal"},
      %SequenceFlow{id: "Flow_BE_NonInt", source_ref: "TimerBE_NonInt", target_ref: "End_NonInt"},
      %SequenceFlow{id: "Flow_BE_Int", source_ref: "TimerBE_Int", target_ref: "End_Int"}
    ]

    wrap_process(
      process_id,
      [
        start,
        user_task,
        timer_non_interrupting,
        timer_interrupting,
        end_normal,
        end_non_int,
        end_int
      ],
      flows
    )
  end

  @doc """
  Build a linear Start → TerminateEndEvent process (single path, no parallel branches).
  """
  def single_path_terminate(process_id \\ "test-process") do
    start = %FlowNode{
      id: "Start_1",
      type: :start_event,
      type_data: %FlowNodeData.StartEvent{event_definition: %EventDefinition.None{}},
      outgoing: ["Flow_1"]
    }

    terminate_end = %FlowNode{
      id: "End_Terminate",
      name: "Terminate",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.Terminate{}},
      incoming: ["Flow_1"]
    }

    flow = %SequenceFlow{id: "Flow_1", source_ref: "Start_1", target_ref: "End_Terminate"}

    wrap_process(process_id, [start, terminate_end], [flow])
  end

  @doc """
  Build a parallel fork where one branch ends with a Terminate End Event
  and the other has a waiting UserTask + normal End Event.

  Start → ParallelGateway → [Task_A → End_Terminate, UserTask_Wait → End_Normal]
  """
  def parallel_with_terminate_end_event(process_id \\ "test-process") do
    start = %FlowNode{
      id: "Start_1",
      type: :start_event,
      type_data: %FlowNodeData.StartEvent{event_definition: %EventDefinition.None{}},
      outgoing: ["Flow_1"]
    }

    fork = %FlowNode{
      id: "Fork_1",
      name: "Fork",
      type: :parallel_gateway,
      type_data: %FlowNodeData.ParallelGateway{},
      incoming: ["Flow_1"],
      outgoing: ["Flow_A", "Flow_B"]
    }

    task_a = %FlowNode{
      id: "Task_A",
      name: "Quick Path",
      type: :task,
      type_data: %FlowNodeData.Task{},
      incoming: ["Flow_A"],
      outgoing: ["Flow_A2"]
    }

    terminate_end = %FlowNode{
      id: "End_Terminate",
      name: "Terminate",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.Terminate{}},
      incoming: ["Flow_A2"]
    }

    user_task = %FlowNode{
      id: "UserTask_Wait",
      name: "Waiting User Task",
      type: :user_task,
      type_data: %FlowNodeData.UserTask{form_schema: %{"fields" => []}},
      incoming: ["Flow_B"],
      outgoing: ["Flow_B2"]
    }

    end_normal = %FlowNode{
      id: "End_Normal",
      name: "Normal End",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
      incoming: ["Flow_B2"]
    }

    flows = [
      %SequenceFlow{id: "Flow_1", source_ref: "Start_1", target_ref: "Fork_1"},
      %SequenceFlow{id: "Flow_A", source_ref: "Fork_1", target_ref: "Task_A"},
      %SequenceFlow{id: "Flow_B", source_ref: "Fork_1", target_ref: "UserTask_Wait"},
      %SequenceFlow{id: "Flow_A2", source_ref: "Task_A", target_ref: "End_Terminate"},
      %SequenceFlow{id: "Flow_B2", source_ref: "UserTask_Wait", target_ref: "End_Normal"}
    ]

    wrap_process(
      process_id,
      [start, fork, task_a, terminate_end, user_task, end_normal],
      flows
    )
  end

  @doc """
  Build a parallel fork where one branch ends with a Terminate End Event
  and the other has a Timer Intermediate Catch Event + normal End Event.
  """
  def parallel_terminate_with_timer(opts \\ []) do
    process_id = Keyword.get(opts, :process_id, "test-process")
    time_duration = Keyword.get(opts, :time_duration, "PT1H")

    start = %FlowNode{
      id: "Start_1",
      type: :start_event,
      type_data: %FlowNodeData.StartEvent{event_definition: %EventDefinition.None{}},
      outgoing: ["Flow_1"]
    }

    fork = %FlowNode{
      id: "Fork_1",
      name: "Fork",
      type: :parallel_gateway,
      type_data: %FlowNodeData.ParallelGateway{},
      incoming: ["Flow_1"],
      outgoing: ["Flow_A", "Flow_B"]
    }

    task_a = %FlowNode{
      id: "Task_A",
      name: "Quick Path",
      type: :task,
      type_data: %FlowNodeData.Task{},
      incoming: ["Flow_A"],
      outgoing: ["Flow_A2"]
    }

    terminate_end = %FlowNode{
      id: "End_Terminate",
      name: "Terminate",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.Terminate{}},
      incoming: ["Flow_A2"]
    }

    timer_catch = %FlowNode{
      id: "TimerCatch_1",
      name: "Wait for Timer",
      type: :intermediate_catch_event,
      type_data: %FlowNodeData.IntermediateCatchEvent{
        event_definition: %EventDefinition.Timer{time_duration: time_duration}
      },
      incoming: ["Flow_B"],
      outgoing: ["Flow_B2"]
    }

    end_normal = %FlowNode{
      id: "End_Normal",
      name: "Normal End",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
      incoming: ["Flow_B2"]
    }

    flows = [
      %SequenceFlow{id: "Flow_1", source_ref: "Start_1", target_ref: "Fork_1"},
      %SequenceFlow{id: "Flow_A", source_ref: "Fork_1", target_ref: "Task_A"},
      %SequenceFlow{id: "Flow_B", source_ref: "Fork_1", target_ref: "TimerCatch_1"},
      %SequenceFlow{id: "Flow_A2", source_ref: "Task_A", target_ref: "End_Terminate"},
      %SequenceFlow{id: "Flow_B2", source_ref: "TimerCatch_1", target_ref: "End_Normal"}
    ]

    wrap_process(
      process_id,
      [start, fork, task_a, terminate_end, timer_catch, end_normal],
      flows
    )
  end

  @doc """
  Build a parallel fork where one branch ends with a Terminate End Event
  and the other has a CallActivity + normal End Event.
  """
  def parallel_terminate_with_call_activity(opts \\ []) do
    process_id = Keyword.get(opts, :process_id, "test-process")
    called_element = Keyword.get(opts, :called_element, "child-process")

    start = %FlowNode{
      id: "Start_1",
      type: :start_event,
      type_data: %FlowNodeData.StartEvent{event_definition: %EventDefinition.None{}},
      outgoing: ["Flow_1"]
    }

    fork = %FlowNode{
      id: "Fork_1",
      name: "Fork",
      type: :parallel_gateway,
      type_data: %FlowNodeData.ParallelGateway{},
      incoming: ["Flow_1"],
      outgoing: ["Flow_A", "Flow_B"]
    }

    task_a = %FlowNode{
      id: "Task_A",
      name: "Quick Path",
      type: :task,
      type_data: %FlowNodeData.Task{},
      incoming: ["Flow_A"],
      outgoing: ["Flow_A2"]
    }

    terminate_end = %FlowNode{
      id: "End_Terminate",
      name: "Terminate",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.Terminate{}},
      incoming: ["Flow_A2"]
    }

    call_activity = %FlowNode{
      id: "CA_1",
      name: "Call Child",
      type: :call_activity,
      type_data: %FlowNodeData.CallActivity{
        called_element: called_element,
        in_mappings: [],
        out_mappings: []
      },
      incoming: ["Flow_B"],
      outgoing: ["Flow_B2"]
    }

    end_normal = %FlowNode{
      id: "End_Normal",
      name: "Normal End",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
      incoming: ["Flow_B2"]
    }

    flows = [
      %SequenceFlow{id: "Flow_1", source_ref: "Start_1", target_ref: "Fork_1"},
      %SequenceFlow{id: "Flow_A", source_ref: "Fork_1", target_ref: "Task_A"},
      %SequenceFlow{id: "Flow_B", source_ref: "Fork_1", target_ref: "CA_1"},
      %SequenceFlow{id: "Flow_A2", source_ref: "Task_A", target_ref: "End_Terminate"},
      %SequenceFlow{id: "Flow_B2", source_ref: "CA_1", target_ref: "End_Normal"}
    ]

    wrap_process(
      process_id,
      [start, fork, task_a, terminate_end, call_activity, end_normal],
      flows
    )
  end

  @doc """
  Build Start → ParallelGateway(split) → Task_A + Task_B → ParallelGateway(join) → End.
  """
  def parallel_fork_join_process(process_id \\ "test-process") do
    start = %FlowNode{
      id: "Start_1",
      type: :start_event,
      type_data: %FlowNodeData.StartEvent{event_definition: %EventDefinition.None{}},
      outgoing: ["Flow_1"]
    }

    fork = %FlowNode{
      id: "Fork_1",
      name: "Fork",
      type: :parallel_gateway,
      type_data: %FlowNodeData.ParallelGateway{},
      incoming: ["Flow_1"],
      outgoing: ["Flow_A", "Flow_B"]
    }

    task_a = %FlowNode{
      id: "Task_A",
      name: "Task A",
      type: :task,
      type_data: %FlowNodeData.Task{},
      incoming: ["Flow_A"],
      outgoing: ["Flow_A2"]
    }

    task_b = %FlowNode{
      id: "Task_B",
      name: "Task B",
      type: :task,
      type_data: %FlowNodeData.Task{},
      incoming: ["Flow_B"],
      outgoing: ["Flow_B2"]
    }

    join = %FlowNode{
      id: "Join_1",
      name: "Join",
      type: :parallel_gateway,
      type_data: %FlowNodeData.ParallelGateway{},
      incoming: ["Flow_A2", "Flow_B2"],
      outgoing: ["Flow_Join"]
    }

    end_event = %FlowNode{
      id: "End_1",
      name: "Done",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
      incoming: ["Flow_Join"]
    }

    flows = [
      %SequenceFlow{id: "Flow_1", source_ref: "Start_1", target_ref: "Fork_1"},
      %SequenceFlow{id: "Flow_A", source_ref: "Fork_1", target_ref: "Task_A"},
      %SequenceFlow{id: "Flow_B", source_ref: "Fork_1", target_ref: "Task_B"},
      %SequenceFlow{id: "Flow_A2", source_ref: "Task_A", target_ref: "Join_1"},
      %SequenceFlow{id: "Flow_B2", source_ref: "Task_B", target_ref: "Join_1"},
      %SequenceFlow{id: "Flow_Join", source_ref: "Join_1", target_ref: "End_1"}
    ]

    wrap_process(process_id, [start, fork, task_a, task_b, join, end_event], flows)
  end

  @doc """
  Build Start → ParallelGateway(split) → End + Task(no outgoing).

  The dead-end branch causes the PI to go fatal.
  """
  def parallel_fork_end_and_dead_end_process(process_id \\ "test-process") do
    start = %FlowNode{
      id: "Start_1",
      type: :start_event,
      type_data: %FlowNodeData.StartEvent{event_definition: %EventDefinition.None{}},
      outgoing: ["Flow_1"]
    }

    fork = %FlowNode{
      id: "Fork_1",
      name: "Fork",
      type: :parallel_gateway,
      type_data: %FlowNodeData.ParallelGateway{},
      incoming: ["Flow_1"],
      outgoing: ["Flow_End", "Flow_Dead"]
    }

    end_quick = %FlowNode{
      id: "End_Quick",
      name: "Quick End",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
      incoming: ["Flow_End"]
    }

    task_dead = %FlowNode{
      id: "Task_Dead",
      name: "Dead End Task",
      type: :task,
      type_data: %FlowNodeData.Task{},
      incoming: ["Flow_Dead"],
      outgoing: []
    }

    flows = [
      %SequenceFlow{id: "Flow_1", source_ref: "Start_1", target_ref: "Fork_1"},
      %SequenceFlow{id: "Flow_End", source_ref: "Fork_1", target_ref: "End_Quick"},
      %SequenceFlow{id: "Flow_Dead", source_ref: "Fork_1", target_ref: "Task_Dead"}
    ]

    wrap_process(process_id, [start, fork, end_quick, task_dead], flows)
  end

  @doc """
  Build Start → EventBasedGateway → TimerCatch(PT0S) + MessageCatch → End.

  The timer catch fires immediately; the message catch is cancelled when
  the timer branch wins.
  """
  def event_based_gateway_timer_message_process(opts \\ []) do
    process_id = Keyword.get(opts, :process_id, "test-process")
    time_duration = Keyword.get(opts, :time_duration, "PT0S")
    message_name = Keyword.get(opts, :message_name, "test-message")

    start = %FlowNode{
      id: "Start_1",
      type: :start_event,
      type_data: %FlowNodeData.StartEvent{event_definition: %EventDefinition.None{}},
      outgoing: ["Flow_1"]
    }

    event_based_gateway = %FlowNode{
      id: "EBG_1",
      name: "Wait for Event",
      type: :event_based_gateway,
      type_data: %FlowNodeData.EventBasedGateway{},
      incoming: ["Flow_1"],
      outgoing: ["Flow_Timer", "Flow_Message"]
    }

    timer_catch = %FlowNode{
      id: "TimerCatch_1",
      name: "Timer Catch",
      type: :intermediate_catch_event,
      type_data: %FlowNodeData.IntermediateCatchEvent{
        event_definition: %EventDefinition.Timer{time_duration: time_duration}
      },
      incoming: ["Flow_Timer"],
      outgoing: ["Flow_Timer_End"]
    }

    message_catch = %FlowNode{
      id: "MessageCatch_1",
      name: "Message Catch",
      type: :intermediate_catch_event,
      type_data: %FlowNodeData.IntermediateCatchEvent{
        event_definition: %EventDefinition.Message{message_ref: "Message_1"}
      },
      incoming: ["Flow_Message"],
      outgoing: ["Flow_Message_End"]
    }

    end_event = %FlowNode{
      id: "End_1",
      name: "Done",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
      incoming: ["Flow_Timer_End", "Flow_Message_End"]
    }

    flows = [
      %SequenceFlow{id: "Flow_1", source_ref: "Start_1", target_ref: "EBG_1"},
      %SequenceFlow{id: "Flow_Timer", source_ref: "EBG_1", target_ref: "TimerCatch_1"},
      %SequenceFlow{id: "Flow_Message", source_ref: "EBG_1", target_ref: "MessageCatch_1"},
      %SequenceFlow{id: "Flow_Timer_End", source_ref: "TimerCatch_1", target_ref: "End_1"},
      %SequenceFlow{id: "Flow_Message_End", source_ref: "MessageCatch_1", target_ref: "End_1"}
    ]

    message_definition = %MessageDefinition{id: "Message_1", name: message_name}

    wrap_process_with_messages(
      process_id,
      [start, event_based_gateway, timer_catch, message_catch, end_event],
      flows,
      [message_definition]
    )
  end

  @doc """
  Build Start → EventBasedGateway → SignalCatch + TimerCatch → End.
  """
  def event_based_gateway_signal_timer_process(opts \\ []) do
    process_id = Keyword.get(opts, :process_id, "test-process")
    time_duration = Keyword.get(opts, :time_duration, "PT10S")
    signal_name = Keyword.get(opts, :signal_name, "test-signal")

    start = %FlowNode{
      id: "Start_1",
      type: :start_event,
      type_data: %FlowNodeData.StartEvent{event_definition: %EventDefinition.None{}},
      outgoing: ["Flow_1"]
    }

    event_based_gateway = %FlowNode{
      id: "EBG_1",
      name: "Wait for Event",
      type: :event_based_gateway,
      type_data: %FlowNodeData.EventBasedGateway{},
      incoming: ["Flow_1"],
      outgoing: ["Flow_Signal", "Flow_Timer"]
    }

    signal_catch = %FlowNode{
      id: "SignalCatch_1",
      name: "Signal Catch",
      type: :intermediate_catch_event,
      type_data: %FlowNodeData.IntermediateCatchEvent{
        event_definition: %EventDefinition.Signal{signal_ref: "Signal_1"}
      },
      incoming: ["Flow_Signal"],
      outgoing: ["Flow_Signal_End"]
    }

    timer_catch = %FlowNode{
      id: "TimerCatch_1",
      name: "Timer Catch",
      type: :intermediate_catch_event,
      type_data: %FlowNodeData.IntermediateCatchEvent{
        event_definition: %EventDefinition.Timer{time_duration: time_duration}
      },
      incoming: ["Flow_Timer"],
      outgoing: ["Flow_Timer_End"]
    }

    end_event = %FlowNode{
      id: "End_1",
      name: "Done",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
      incoming: ["Flow_Signal_End", "Flow_Timer_End"]
    }

    flows = [
      %SequenceFlow{id: "Flow_1", source_ref: "Start_1", target_ref: "EBG_1"},
      %SequenceFlow{id: "Flow_Signal", source_ref: "EBG_1", target_ref: "SignalCatch_1"},
      %SequenceFlow{id: "Flow_Timer", source_ref: "EBG_1", target_ref: "TimerCatch_1"},
      %SequenceFlow{id: "Flow_Signal_End", source_ref: "SignalCatch_1", target_ref: "End_1"},
      %SequenceFlow{id: "Flow_Timer_End", source_ref: "TimerCatch_1", target_ref: "End_1"}
    ]

    signal_definition = %SignalDefinition{id: "Signal_1", name: signal_name}

    process = %BpmnProcess{
      id: process_id,
      name: "Test Process",
      version: "1.0.0",
      is_executable: true,
      flow_nodes: [start, event_based_gateway, signal_catch, timer_catch, end_event],
      sequence_flows: flows
    }

    %Definitions{
      processes: [process],
      signals: [signal_definition],
      raw_xml: ""
    }
  end

  @doc """
  Build Start → EventBasedGateway → MessageCatch + SignalCatch → End.
  """
  def event_based_gateway_message_signal_process(opts \\ []) do
    process_id = Keyword.get(opts, :process_id, "test-process")
    message_name = Keyword.get(opts, :message_name, "test-message")
    signal_name = Keyword.get(opts, :signal_name, "test-signal")

    start = %FlowNode{
      id: "Start_1",
      type: :start_event,
      type_data: %FlowNodeData.StartEvent{event_definition: %EventDefinition.None{}},
      outgoing: ["Flow_1"]
    }

    event_based_gateway = %FlowNode{
      id: "EBG_1",
      name: "Wait for Event",
      type: :event_based_gateway,
      type_data: %FlowNodeData.EventBasedGateway{},
      incoming: ["Flow_1"],
      outgoing: ["Flow_Message", "Flow_Signal"]
    }

    message_catch = %FlowNode{
      id: "MessageCatch_1",
      name: "Message Catch",
      type: :intermediate_catch_event,
      type_data: %FlowNodeData.IntermediateCatchEvent{
        event_definition: %EventDefinition.Message{message_ref: "Message_1"}
      },
      incoming: ["Flow_Message"],
      outgoing: ["Flow_Message_End"]
    }

    signal_catch = %FlowNode{
      id: "SignalCatch_1",
      name: "Signal Catch",
      type: :intermediate_catch_event,
      type_data: %FlowNodeData.IntermediateCatchEvent{
        event_definition: %EventDefinition.Signal{signal_ref: "Signal_1"}
      },
      incoming: ["Flow_Signal"],
      outgoing: ["Flow_Signal_End"]
    }

    end_event = %FlowNode{
      id: "End_1",
      name: "Done",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
      incoming: ["Flow_Message_End", "Flow_Signal_End"]
    }

    flows = [
      %SequenceFlow{id: "Flow_1", source_ref: "Start_1", target_ref: "EBG_1"},
      %SequenceFlow{id: "Flow_Message", source_ref: "EBG_1", target_ref: "MessageCatch_1"},
      %SequenceFlow{id: "Flow_Signal", source_ref: "EBG_1", target_ref: "SignalCatch_1"},
      %SequenceFlow{id: "Flow_Message_End", source_ref: "MessageCatch_1", target_ref: "End_1"},
      %SequenceFlow{id: "Flow_Signal_End", source_ref: "SignalCatch_1", target_ref: "End_1"}
    ]

    message_definition = %MessageDefinition{id: "Message_1", name: message_name}
    signal_definition = %SignalDefinition{id: "Signal_1", name: signal_name}

    process = %BpmnProcess{
      id: process_id,
      name: "Test Process",
      version: "1.0.0",
      is_executable: true,
      flow_nodes: [start, event_based_gateway, message_catch, signal_catch, end_event],
      sequence_flows: flows
    }

    %Definitions{
      processes: [process],
      messages: [message_definition],
      signals: [signal_definition],
      raw_xml: ""
    }
  end

  @doc """
  Build Start → EventBasedGateway → ReceiveTask(message A) + ReceiveTask(message B) → End.

  Both receive tasks wait for different messages.
  """
  def event_based_gateway_receive_task_process(opts \\ []) do
    process_id = Keyword.get(opts, :process_id, "test-process")
    message_name_a = Keyword.get(opts, :message_name_a, "message-a")
    message_name_b = Keyword.get(opts, :message_name_b, "message-b")

    start = %FlowNode{
      id: "Start_1",
      type: :start_event,
      type_data: %FlowNodeData.StartEvent{event_definition: %EventDefinition.None{}},
      outgoing: ["Flow_1"]
    }

    event_based_gateway = %FlowNode{
      id: "EBG_1",
      name: "Wait for Event",
      type: :event_based_gateway,
      type_data: %FlowNodeData.EventBasedGateway{},
      incoming: ["Flow_1"],
      outgoing: ["Flow_RecvA", "Flow_RecvB"]
    }

    receive_task_a = %FlowNode{
      id: "ReceiveTask_A",
      name: "Receive A",
      type: :receive_task,
      type_data: %FlowNodeData.ReceiveTask{message_ref: "Message_A"},
      incoming: ["Flow_RecvA"],
      outgoing: ["Flow_RecvA_End"]
    }

    receive_task_b = %FlowNode{
      id: "ReceiveTask_B",
      name: "Receive B",
      type: :receive_task,
      type_data: %FlowNodeData.ReceiveTask{message_ref: "Message_B"},
      incoming: ["Flow_RecvB"],
      outgoing: ["Flow_RecvB_End"]
    }

    end_event = %FlowNode{
      id: "End_1",
      name: "Done",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
      incoming: ["Flow_RecvA_End", "Flow_RecvB_End"]
    }

    flows = [
      %SequenceFlow{id: "Flow_1", source_ref: "Start_1", target_ref: "EBG_1"},
      %SequenceFlow{id: "Flow_RecvA", source_ref: "EBG_1", target_ref: "ReceiveTask_A"},
      %SequenceFlow{id: "Flow_RecvB", source_ref: "EBG_1", target_ref: "ReceiveTask_B"},
      %SequenceFlow{id: "Flow_RecvA_End", source_ref: "ReceiveTask_A", target_ref: "End_1"},
      %SequenceFlow{id: "Flow_RecvB_End", source_ref: "ReceiveTask_B", target_ref: "End_1"}
    ]

    message_definition_a = %MessageDefinition{id: "Message_A", name: message_name_a}
    message_definition_b = %MessageDefinition{id: "Message_B", name: message_name_b}

    wrap_process_with_messages(
      process_id,
      [start, event_based_gateway, receive_task_a, receive_task_b, end_event],
      flows,
      [message_definition_a, message_definition_b]
    )
  end

  @doc """
  Build Start → EventBasedGateway → TimerCatch + MessageCatch + SignalCatch → End.

  Three-way race: whichever fires first wins and the other two are cancelled.
  """
  def event_based_gateway_three_branches_process(opts \\ []) do
    process_id = Keyword.get(opts, :process_id, "test-process")
    time_duration = Keyword.get(opts, :time_duration, "PT0S")
    message_name = Keyword.get(opts, :message_name, "test-message")
    signal_name = Keyword.get(opts, :signal_name, "test-signal")

    start = %FlowNode{
      id: "Start_1",
      type: :start_event,
      type_data: %FlowNodeData.StartEvent{event_definition: %EventDefinition.None{}},
      outgoing: ["Flow_1"]
    }

    event_based_gateway = %FlowNode{
      id: "EBG_1",
      name: "Wait for Event",
      type: :event_based_gateway,
      type_data: %FlowNodeData.EventBasedGateway{},
      incoming: ["Flow_1"],
      outgoing: ["Flow_Timer", "Flow_Message", "Flow_Signal"]
    }

    timer_catch = %FlowNode{
      id: "TimerCatch_1",
      name: "Timer Catch",
      type: :intermediate_catch_event,
      type_data: %FlowNodeData.IntermediateCatchEvent{
        event_definition: %EventDefinition.Timer{time_duration: time_duration}
      },
      incoming: ["Flow_Timer"],
      outgoing: ["Flow_Timer_End"]
    }

    message_catch = %FlowNode{
      id: "MessageCatch_1",
      name: "Message Catch",
      type: :intermediate_catch_event,
      type_data: %FlowNodeData.IntermediateCatchEvent{
        event_definition: %EventDefinition.Message{message_ref: "Message_1"}
      },
      incoming: ["Flow_Message"],
      outgoing: ["Flow_Message_End"]
    }

    signal_catch = %FlowNode{
      id: "SignalCatch_1",
      name: "Signal Catch",
      type: :intermediate_catch_event,
      type_data: %FlowNodeData.IntermediateCatchEvent{
        event_definition: %EventDefinition.Signal{signal_ref: "Signal_1"}
      },
      incoming: ["Flow_Signal"],
      outgoing: ["Flow_Signal_End"]
    }

    end_event = %FlowNode{
      id: "End_1",
      name: "Done",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
      incoming: ["Flow_Timer_End", "Flow_Message_End", "Flow_Signal_End"]
    }

    flows = [
      %SequenceFlow{id: "Flow_1", source_ref: "Start_1", target_ref: "EBG_1"},
      %SequenceFlow{id: "Flow_Timer", source_ref: "EBG_1", target_ref: "TimerCatch_1"},
      %SequenceFlow{id: "Flow_Message", source_ref: "EBG_1", target_ref: "MessageCatch_1"},
      %SequenceFlow{id: "Flow_Signal", source_ref: "EBG_1", target_ref: "SignalCatch_1"},
      %SequenceFlow{id: "Flow_Timer_End", source_ref: "TimerCatch_1", target_ref: "End_1"},
      %SequenceFlow{id: "Flow_Message_End", source_ref: "MessageCatch_1", target_ref: "End_1"},
      %SequenceFlow{id: "Flow_Signal_End", source_ref: "SignalCatch_1", target_ref: "End_1"}
    ]

    message_definition = %MessageDefinition{id: "Message_1", name: message_name}
    signal_definition = %SignalDefinition{id: "Signal_1", name: signal_name}

    process = %BpmnProcess{
      id: process_id,
      name: "Test Process",
      version: "1.0.0",
      is_executable: true,
      flow_nodes: [
        start,
        event_based_gateway,
        timer_catch,
        message_catch,
        signal_catch,
        end_event
      ],
      sequence_flows: flows
    }

    %Definitions{
      processes: [process],
      messages: [message_definition],
      signals: [signal_definition],
      raw_xml: ""
    }
  end

  @doc """
  Build Start → EBG → TimerCatch → ErrorEndEvent; EBG → MessageCatch → End.

  Used to test the winning catch leading to an Error End Event.
  """
  def event_based_gateway_timer_to_error_end_process(opts \\ []) do
    process_id = Keyword.get(opts, :process_id, "test-process")
    time_duration = Keyword.get(opts, :time_duration, "PT0S")
    message_name = Keyword.get(opts, :message_name, "test-message")

    start = %FlowNode{
      id: "Start_1",
      type: :start_event,
      type_data: %FlowNodeData.StartEvent{event_definition: %EventDefinition.None{}},
      outgoing: ["Flow_1"]
    }

    event_based_gateway = %FlowNode{
      id: "EBG_1",
      name: "Wait for Event",
      type: :event_based_gateway,
      type_data: %FlowNodeData.EventBasedGateway{},
      incoming: ["Flow_1"],
      outgoing: ["Flow_Timer", "Flow_Message"]
    }

    timer_catch = %FlowNode{
      id: "TimerCatch_1",
      name: "Timer Catch",
      type: :intermediate_catch_event,
      type_data: %FlowNodeData.IntermediateCatchEvent{
        event_definition: %EventDefinition.Timer{time_duration: time_duration}
      },
      incoming: ["Flow_Timer"],
      outgoing: ["Flow_Timer_Error"]
    }

    error_end = %FlowNode{
      id: "ErrorEnd_1",
      name: "Error",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{
        event_definition: %EventDefinition.Error{
          error_ref: nil,
          error_code: "EBG_ERROR",
          error_message: "Timer branch error"
        }
      },
      incoming: ["Flow_Timer_Error"]
    }

    message_catch = %FlowNode{
      id: "MessageCatch_1",
      name: "Message Catch",
      type: :intermediate_catch_event,
      type_data: %FlowNodeData.IntermediateCatchEvent{
        event_definition: %EventDefinition.Message{message_ref: "Message_1"}
      },
      incoming: ["Flow_Message"],
      outgoing: ["Flow_Message_End"]
    }

    end_event = %FlowNode{
      id: "End_1",
      name: "Done",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
      incoming: ["Flow_Message_End"]
    }

    flows = [
      %SequenceFlow{id: "Flow_1", source_ref: "Start_1", target_ref: "EBG_1"},
      %SequenceFlow{id: "Flow_Timer", source_ref: "EBG_1", target_ref: "TimerCatch_1"},
      %SequenceFlow{id: "Flow_Message", source_ref: "EBG_1", target_ref: "MessageCatch_1"},
      %SequenceFlow{id: "Flow_Timer_Error", source_ref: "TimerCatch_1", target_ref: "ErrorEnd_1"},
      %SequenceFlow{id: "Flow_Message_End", source_ref: "MessageCatch_1", target_ref: "End_1"}
    ]

    message_definition = %MessageDefinition{id: "Message_1", name: message_name}

    wrap_process_with_messages(
      process_id,
      [start, event_based_gateway, timer_catch, error_end, message_catch, end_event],
      flows,
      [message_definition]
    )
  end

  @doc """
  Build Start → EBG → TimerCatch → ScriptTask(fail) → End; EBG → MessageCatch → End.

  The ScriptTask uses `implementation: "fail"` to simulate a fatal handler.
  Used to test winning catch leading to a fatal downstream successor.
  """
  def event_based_gateway_timer_to_fatal_script_process(opts \\ []) do
    process_id = Keyword.get(opts, :process_id, "test-process")
    time_duration = Keyword.get(opts, :time_duration, "PT0S")
    message_name = Keyword.get(opts, :message_name, "test-message")

    start = %FlowNode{
      id: "Start_1",
      type: :start_event,
      type_data: %FlowNodeData.StartEvent{event_definition: %EventDefinition.None{}},
      outgoing: ["Flow_1"]
    }

    event_based_gateway = %FlowNode{
      id: "EBG_1",
      name: "Wait for Event",
      type: :event_based_gateway,
      type_data: %FlowNodeData.EventBasedGateway{},
      incoming: ["Flow_1"],
      outgoing: ["Flow_Timer", "Flow_Message"]
    }

    timer_catch = %FlowNode{
      id: "TimerCatch_1",
      name: "Timer Catch",
      type: :intermediate_catch_event,
      type_data: %FlowNodeData.IntermediateCatchEvent{
        event_definition: %EventDefinition.Timer{time_duration: time_duration}
      },
      incoming: ["Flow_Timer"],
      outgoing: ["Flow_Timer_Script"]
    }

    fatal_script = %FlowNode{
      id: "FatalScript_1",
      name: "Fatal Script",
      type: :script_task,
      type_data: %FlowNodeData.ScriptTask{
        script_format: "feel",
        script: "this_will_fail("
      },
      incoming: ["Flow_Timer_Script"],
      outgoing: ["Flow_Script_End"]
    }

    message_catch = %FlowNode{
      id: "MessageCatch_1",
      name: "Message Catch",
      type: :intermediate_catch_event,
      type_data: %FlowNodeData.IntermediateCatchEvent{
        event_definition: %EventDefinition.Message{message_ref: "Message_1"}
      },
      incoming: ["Flow_Message"],
      outgoing: ["Flow_Message_End"]
    }

    end_event = %FlowNode{
      id: "End_1",
      name: "Done",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
      incoming: ["Flow_Script_End", "Flow_Message_End"]
    }

    flows = [
      %SequenceFlow{id: "Flow_1", source_ref: "Start_1", target_ref: "EBG_1"},
      %SequenceFlow{id: "Flow_Timer", source_ref: "EBG_1", target_ref: "TimerCatch_1"},
      %SequenceFlow{id: "Flow_Message", source_ref: "EBG_1", target_ref: "MessageCatch_1"},
      %SequenceFlow{
        id: "Flow_Timer_Script",
        source_ref: "TimerCatch_1",
        target_ref: "FatalScript_1"
      },
      %SequenceFlow{id: "Flow_Script_End", source_ref: "FatalScript_1", target_ref: "End_1"},
      %SequenceFlow{id: "Flow_Message_End", source_ref: "MessageCatch_1", target_ref: "End_1"}
    ]

    message_definition = %MessageDefinition{id: "Message_1", name: message_name}

    wrap_process_with_messages(
      process_id,
      [start, event_based_gateway, timer_catch, fatal_script, message_catch, end_event],
      flows,
      [message_definition]
    )
  end

  @doc """
  Build Start → EBG → ReceiveTask(message A) + TimerCatch → End.

  Mixed EBG with one Receive Task and one Timer catch event.
  """
  def event_based_gateway_receive_task_timer_process(opts \\ []) do
    process_id = Keyword.get(opts, :process_id, "test-process")
    time_duration = Keyword.get(opts, :time_duration, "PT10S")
    message_name = Keyword.get(opts, :message_name, "test-message")

    start = %FlowNode{
      id: "Start_1",
      type: :start_event,
      type_data: %FlowNodeData.StartEvent{event_definition: %EventDefinition.None{}},
      outgoing: ["Flow_1"]
    }

    event_based_gateway = %FlowNode{
      id: "EBG_1",
      name: "Wait for Event",
      type: :event_based_gateway,
      type_data: %FlowNodeData.EventBasedGateway{},
      incoming: ["Flow_1"],
      outgoing: ["Flow_Recv", "Flow_Timer"]
    }

    receive_task = %FlowNode{
      id: "ReceiveTask_1",
      name: "Receive Message",
      type: :receive_task,
      type_data: %FlowNodeData.ReceiveTask{message_ref: "Message_1"},
      incoming: ["Flow_Recv"],
      outgoing: ["Flow_Recv_End"]
    }

    timer_catch = %FlowNode{
      id: "TimerCatch_1",
      name: "Timer Catch",
      type: :intermediate_catch_event,
      type_data: %FlowNodeData.IntermediateCatchEvent{
        event_definition: %EventDefinition.Timer{time_duration: time_duration}
      },
      incoming: ["Flow_Timer"],
      outgoing: ["Flow_Timer_End"]
    }

    end_event = %FlowNode{
      id: "End_1",
      name: "Done",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
      incoming: ["Flow_Recv_End", "Flow_Timer_End"]
    }

    flows = [
      %SequenceFlow{id: "Flow_1", source_ref: "Start_1", target_ref: "EBG_1"},
      %SequenceFlow{id: "Flow_Recv", source_ref: "EBG_1", target_ref: "ReceiveTask_1"},
      %SequenceFlow{id: "Flow_Timer", source_ref: "EBG_1", target_ref: "TimerCatch_1"},
      %SequenceFlow{id: "Flow_Recv_End", source_ref: "ReceiveTask_1", target_ref: "End_1"},
      %SequenceFlow{id: "Flow_Timer_End", source_ref: "TimerCatch_1", target_ref: "End_1"}
    ]

    message_definition = %MessageDefinition{id: "Message_1", name: message_name}

    wrap_process_with_messages(
      process_id,
      [start, event_based_gateway, receive_task, timer_catch, end_event],
      flows,
      [message_definition]
    )
  end

  @doc """
  Build a Start → embedded SubProcess → End process.

  The embedded subprocess contains Start → Task → End internally.
  Runtime has no SubProcess handler yet, so the parent PI should go fatal.
  """
  def embedded_sub_process_process(process_id \\ "test-process") do
    sub_start = %FlowNode{
      id: "Sub_Start_1",
      type: :start_event,
      type_data: %FlowNodeData.StartEvent{event_definition: %EventDefinition.None{}},
      outgoing: ["Sub_Flow_1"]
    }

    sub_task = %FlowNode{
      id: "Sub_Task_1",
      name: "Inner Task",
      type: :task,
      type_data: %FlowNodeData.Task{},
      incoming: ["Sub_Flow_1"],
      outgoing: ["Sub_Flow_2"]
    }

    sub_end = %FlowNode{
      id: "Sub_End_1",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
      incoming: ["Sub_Flow_2"]
    }

    sub_process_flows = [
      %SequenceFlow{id: "Sub_Flow_1", source_ref: "Sub_Start_1", target_ref: "Sub_Task_1"},
      %SequenceFlow{id: "Sub_Flow_2", source_ref: "Sub_Task_1", target_ref: "Sub_End_1"}
    ]

    start = %FlowNode{
      id: "Start_1",
      type: :start_event,
      type_data: %FlowNodeData.StartEvent{event_definition: %EventDefinition.None{}},
      outgoing: ["Flow_1"]
    }

    sub_process = %FlowNode{
      id: "SubProcess_1",
      name: "Embedded",
      type: :sub_process,
      type_data: %FlowNodeData.SubProcess{
        triggered_by_event: false,
        flow_nodes: [sub_start, sub_task, sub_end],
        sequence_flows: sub_process_flows
      },
      incoming: ["Flow_1"],
      outgoing: ["Flow_2"]
    }

    end_event = %FlowNode{
      id: "End_1",
      name: "Done",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
      incoming: ["Flow_2"]
    }

    flows = [
      %SequenceFlow{id: "Flow_1", source_ref: "Start_1", target_ref: "SubProcess_1"},
      %SequenceFlow{id: "Flow_2", source_ref: "SubProcess_1", target_ref: "End_1"}
    ]

    wrap_process(process_id, [start, sub_process, end_event], flows)
  end

  @doc """
  Build a Start → multi-instance Task → End process.

  Options:
  - `:is_sequential` — defaults to `true`
  - `:collection_expression` — FEEL expression for the input collection
  - `:output_collection` — FEEL expression for aggregated output
  - `:flow_node_type` — `:task` (default) or `:user_task`
  """
  def multi_instance_task_process(opts \\ []) do
    process_id = Keyword.get(opts, :process_id, "test-process")
    is_sequential = Keyword.get(opts, :is_sequential, true)
    collection_expression = Keyword.get(opts, :collection_expression, "token.items")
    output_collection = Keyword.get(opts, :output_collection, "processedItems")
    flow_node_type = Keyword.get(opts, :flow_node_type, :task)
    completion_condition = Keyword.get(opts, :completion_condition)

    multi_instance = %MultiInstance{
      is_sequential: is_sequential,
      collection_expression: collection_expression,
      output_collection: output_collection,
      completion_condition: completion_condition
    }

    start = %FlowNode{
      id: "Start_1",
      type: :start_event,
      type_data: %FlowNodeData.StartEvent{event_definition: %EventDefinition.None{}},
      outgoing: ["Flow_1"]
    }

    multi_instance_task =
      build_multi_instance_flow_node(
        flow_node_type,
        multi_instance,
        incoming: ["Flow_1"],
        outgoing: ["Flow_2"]
      )

    end_event = %FlowNode{
      id: "End_1",
      name: "Done",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
      incoming: ["Flow_2"]
    }

    flows = [
      %SequenceFlow{id: "Flow_1", source_ref: "Start_1", target_ref: multi_instance_task.id},
      %SequenceFlow{id: "Flow_2", source_ref: multi_instance_task.id, target_ref: "End_1"}
    ]

    wrap_process(process_id, [start, multi_instance_task, end_event], flows)
  end

  defp build_multi_instance_flow_node(:task, multi_instance, connection_attributes) do
    %FlowNode{
      id: "Task_MI_1",
      name: "Multi-Instance Task",
      type: :task,
      type_data: %FlowNodeData.Task{},
      multi_instance: multi_instance,
      incoming: connection_attributes[:incoming],
      outgoing: connection_attributes[:outgoing]
    }
  end

  defp build_multi_instance_flow_node(:user_task, multi_instance, connection_attributes) do
    %FlowNode{
      id: "UserTask_MI_1",
      name: "Multi-Instance User Task",
      type: :user_task,
      type_data: %FlowNodeData.UserTask{form_schema: %{"fields" => []}},
      multi_instance: multi_instance,
      incoming: connection_attributes[:incoming],
      outgoing: connection_attributes[:outgoing]
    }
  end

  defp wrap_process_with_messages(process_id, nodes, flows, messages) do
    process = %BpmnProcess{
      id: process_id,
      name: "Test Process",
      version: "1.0.0",
      is_executable: true,
      flow_nodes: nodes,
      sequence_flows: flows
    }

    %Definitions{
      processes: [process],
      messages: messages,
      raw_xml: ""
    }
  end

  @doc """
  Build a Start → IntermediateThrowEvent(compensation) → End process.
  """
  def compensation_throw_process(process_id \\ "test-process") do
    start = %FlowNode{
      id: "Start_1",
      type: :start_event,
      type_data: %FlowNodeData.StartEvent{event_definition: %EventDefinition.None{}},
      outgoing: ["Flow_1"]
    }

    compensation_throw = %FlowNode{
      id: "Throw_Compensation",
      name: "Throw Compensation",
      type: :intermediate_throw_event,
      type_data: %FlowNodeData.IntermediateThrowEvent{
        event_definition: %EventDefinition.Compensation{}
      },
      incoming: ["Flow_1"],
      outgoing: ["Flow_2"]
    }

    end_event = %FlowNode{
      id: "End_1",
      name: "Done",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
      incoming: ["Flow_2"]
    }

    flows = [
      %SequenceFlow{id: "Flow_1", source_ref: "Start_1", target_ref: "Throw_Compensation"},
      %SequenceFlow{id: "Flow_2", source_ref: "Throw_Compensation", target_ref: "End_1"}
    ]

    wrap_process(process_id, [start, compensation_throw, end_event], flows)
  end

  @doc """
  Build Start → Task (with compensation handler) → Compensate Throw → End.
  """
  def compensation_with_handler_process(process_id \\ "test-process") do
    start = %FlowNode{
      id: "Start_1",
      type: :start_event,
      type_data: %FlowNodeData.StartEvent{event_definition: %EventDefinition.None{}},
      outgoing: ["Flow_1"]
    }

    book_task = %FlowNode{
      id: "Task_Book",
      name: "Book",
      type: :task,
      type_data: %FlowNodeData.Task{},
      incoming: ["Flow_1"],
      outgoing: ["Flow_2"],
      boundary_event_refs: ["BE_Comp"]
    }

    compensation_boundary = %FlowNode{
      id: "BE_Comp",
      type: :boundary_event,
      type_data: %FlowNodeData.BoundaryEvent{
        attached_to_ref: "Task_Book",
        cancel_activity: false,
        event_definition: %EventDefinition.Compensation{},
        compensation_handler_id: "Task_Undo"
      }
    }

    undo_task = %FlowNode{
      id: "Task_Undo",
      name: "Undo Booking",
      type: :task,
      type_data: %FlowNodeData.Task{},
      is_for_compensation: true
    }

    compensation_throw = %FlowNode{
      id: "Throw_Compensation",
      name: "Throw Compensation",
      type: :intermediate_throw_event,
      type_data: %FlowNodeData.IntermediateThrowEvent{
        event_definition: %EventDefinition.Compensation{}
      },
      incoming: ["Flow_2"],
      outgoing: ["Flow_3"]
    }

    end_event = %FlowNode{
      id: "End_1",
      name: "Done",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
      incoming: ["Flow_3"]
    }

    flows = [
      %SequenceFlow{id: "Flow_1", source_ref: "Start_1", target_ref: "Task_Book"},
      %SequenceFlow{id: "Flow_2", source_ref: "Task_Book", target_ref: "Throw_Compensation"},
      %SequenceFlow{id: "Flow_3", source_ref: "Throw_Compensation", target_ref: "End_1"}
    ]

    wrap_process(
      process_id,
      [start, book_task, compensation_boundary, undo_task, compensation_throw, end_event],
      flows
    )
  end

  @doc """
  Build Start → Compensate End. The process instance terminates as `:compensated`.
  """
  def compensate_end_process(process_id \\ "child-process") do
    start = %FlowNode{
      id: "Start_1",
      type: :start_event,
      type_data: %FlowNodeData.StartEvent{event_definition: %EventDefinition.None{}},
      outgoing: ["Flow_1"]
    }

    compensate_end = %FlowNode{
      id: "End_Compensate",
      name: "Compensate End",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{
        event_definition: %EventDefinition.Compensation{}
      },
      incoming: ["Flow_1"]
    }

    flow = %SequenceFlow{id: "Flow_1", source_ref: "Start_1", target_ref: "End_Compensate"}

    wrap_process(process_id, [start, compensate_end], [flow])
  end

  @doc """
  Build Start → Compensate Throw → End with an interrupting compensation ESP.
  """
  def compensation_throw_with_esp_process(process_id \\ "test-process") do
    start = %FlowNode{
      id: "Start_1",
      type: :start_event,
      type_data: %FlowNodeData.StartEvent{event_definition: %EventDefinition.None{}},
      outgoing: ["Flow_1"]
    }

    compensation_throw = %FlowNode{
      id: "Throw_Compensation",
      name: "Throw Compensation",
      type: :intermediate_throw_event,
      type_data: %FlowNodeData.IntermediateThrowEvent{
        event_definition: %EventDefinition.Compensation{}
      },
      incoming: ["Flow_1"],
      outgoing: ["Flow_2"]
    }

    end_event = %FlowNode{
      id: "End_1",
      name: "Done",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
      incoming: ["Flow_2"]
    }

    esp_start = %FlowNode{
      id: "ESP_Start",
      type: :start_event,
      type_data: %FlowNodeData.StartEvent{
        event_definition: %EventDefinition.Compensation{},
        is_interrupting: true
      },
      outgoing: ["ESP_F1"]
    }

    esp_task = %FlowNode{
      id: "ESP_Task",
      type: :task,
      type_data: %FlowNodeData.Task{},
      incoming: ["ESP_F1"],
      outgoing: ["ESP_F2"]
    }

    esp_end = %FlowNode{
      id: "ESP_End",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
      incoming: ["ESP_F2"]
    }

    esp = %FlowNode{
      id: "ESP_Comp",
      type: :sub_process,
      type_data: %FlowNodeData.SubProcess{
        triggered_by_event: true,
        flow_nodes: [esp_start, esp_task, esp_end],
        sequence_flows: [
          %SequenceFlow{id: "ESP_F1", source_ref: "ESP_Start", target_ref: "ESP_Task"},
          %SequenceFlow{id: "ESP_F2", source_ref: "ESP_Task", target_ref: "ESP_End"}
        ]
      }
    }

    flows = [
      %SequenceFlow{id: "Flow_1", source_ref: "Start_1", target_ref: "Throw_Compensation"},
      %SequenceFlow{id: "Flow_2", source_ref: "Throw_Compensation", target_ref: "End_1"}
    ]

    wrap_process(process_id, [start, compensation_throw, end_event, esp], flows)
  end

  @doc """
  Build a Start → IntermediateThrowEvent(escalation) → End process.
  """
  def escalation_throw_process(process_id \\ "test-process") do
    start = %FlowNode{
      id: "Start_1",
      type: :start_event,
      type_data: %FlowNodeData.StartEvent{event_definition: %EventDefinition.None{}},
      outgoing: ["Flow_1"]
    }

    escalation_throw = %FlowNode{
      id: "Throw_Escalation",
      name: "Throw Escalation",
      type: :intermediate_throw_event,
      type_data: %FlowNodeData.IntermediateThrowEvent{
        event_definition: %EventDefinition.Escalation{escalation_ref: "Escalation_1"}
      },
      incoming: ["Flow_1"],
      outgoing: ["Flow_2"]
    }

    end_event = %FlowNode{
      id: "End_1",
      name: "Done",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
      incoming: ["Flow_2"]
    }

    flows = [
      %SequenceFlow{id: "Flow_1", source_ref: "Start_1", target_ref: "Throw_Escalation"},
      %SequenceFlow{id: "Flow_2", source_ref: "Throw_Escalation", target_ref: "End_1"}
    ]

    wrap_process(process_id, [start, escalation_throw, end_event], flows)
  end

  @doc """
  Build a Start → EndEvent(cancel) process.
  """
  def cancel_end_event_process(process_id \\ "test-process") do
    start = %FlowNode{
      id: "Start_1",
      type: :start_event,
      type_data: %FlowNodeData.StartEvent{event_definition: %EventDefinition.None{}},
      outgoing: ["Flow_1"]
    }

    cancel_end = %FlowNode{
      id: "End_Cancel",
      name: "Cancel",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.Cancel{}},
      incoming: ["Flow_1"]
    }

    flow = %SequenceFlow{id: "Flow_1", source_ref: "Start_1", target_ref: "End_Cancel"}

    wrap_process(process_id, [start, cancel_end], [flow])
  end

  @doc """
  Build a Start → IntermediateCatchEvent(conditional) → End process.
  """
  def conditional_catch_process(process_id \\ "test-process") do
    start = %FlowNode{
      id: "Start_1",
      type: :start_event,
      type_data: %FlowNodeData.StartEvent{event_definition: %EventDefinition.None{}},
      outgoing: ["Flow_1"]
    }

    conditional_catch = %FlowNode{
      id: "Catch_Conditional",
      name: "Wait for Condition",
      type: :intermediate_catch_event,
      type_data: %FlowNodeData.IntermediateCatchEvent{
        event_definition: %EventDefinition.Conditional{
          condition_expression: "token.ready = true"
        }
      },
      incoming: ["Flow_1"],
      outgoing: ["Flow_2"]
    }

    end_event = %FlowNode{
      id: "End_1",
      name: "Done",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
      incoming: ["Flow_2"]
    }

    flows = [
      %SequenceFlow{id: "Flow_1", source_ref: "Start_1", target_ref: "Catch_Conditional"},
      %SequenceFlow{id: "Flow_2", source_ref: "Catch_Conditional", target_ref: "End_1"}
    ]

    wrap_process(process_id, [start, conditional_catch, end_event], flows)
  end

  defp wrap_process(process_id, nodes, flows) do
    process = %BpmnProcess{
      id: process_id,
      name: "Test Process",
      version: "1.0.0",
      is_executable: true,
      flow_nodes: nodes,
      sequence_flows: flows
    }

    %Definitions{
      processes: [process],
      raw_xml: ""
    }
  end

  @doc """
  Build a converging EventBasedGateway (2 incoming flows) — handler should reject.

  Start → PG_Split → Task_A → EBG_1 → TimerCatch → End
                   → Task_B → EBG_1 (second incoming)
  """
  def event_based_gateway_converging_process(opts \\ []) do
    process_id = Keyword.get(opts, :process_id, "test-process")

    start = %FlowNode{
      id: "Start_1",
      type: :start_event,
      type_data: %FlowNodeData.StartEvent{event_definition: %EventDefinition.None{}},
      outgoing: ["Flow_S1"]
    }

    parallel_gateway = %FlowNode{
      id: "PG_Split",
      name: "Parallel Split",
      type: :parallel_gateway,
      type_data: %FlowNodeData.ParallelGateway{},
      incoming: ["Flow_S1"],
      outgoing: ["Flow_PG_A", "Flow_PG_B"]
    }

    task_a = %FlowNode{
      id: "Task_A",
      type: :task,
      type_data: %FlowNodeData.Task{},
      incoming: ["Flow_PG_A"],
      outgoing: ["Flow_A_EBG"]
    }

    task_b = %FlowNode{
      id: "Task_B",
      type: :task,
      type_data: %FlowNodeData.Task{},
      incoming: ["Flow_PG_B"],
      outgoing: ["Flow_B_EBG"]
    }

    event_based_gateway = %FlowNode{
      id: "EBG_1",
      name: "Converging EBG",
      type: :event_based_gateway,
      type_data: %FlowNodeData.EventBasedGateway{},
      incoming: ["Flow_A_EBG", "Flow_B_EBG"],
      outgoing: ["Flow_Timer"]
    }

    timer_catch = %FlowNode{
      id: "TimerCatch_1",
      type: :intermediate_catch_event,
      type_data: %FlowNodeData.IntermediateCatchEvent{
        event_definition: %EventDefinition.Timer{time_duration: "PT0S"}
      },
      incoming: ["Flow_Timer"],
      outgoing: ["Flow_Timer_End"]
    }

    end_event = %FlowNode{
      id: "End_1",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
      incoming: ["Flow_Timer_End"]
    }

    flows = [
      %SequenceFlow{id: "Flow_S1", source_ref: "Start_1", target_ref: "PG_Split"},
      %SequenceFlow{id: "Flow_PG_A", source_ref: "PG_Split", target_ref: "Task_A"},
      %SequenceFlow{id: "Flow_PG_B", source_ref: "PG_Split", target_ref: "Task_B"},
      %SequenceFlow{id: "Flow_A_EBG", source_ref: "Task_A", target_ref: "EBG_1"},
      %SequenceFlow{id: "Flow_B_EBG", source_ref: "Task_B", target_ref: "EBG_1"},
      %SequenceFlow{id: "Flow_Timer", source_ref: "EBG_1", target_ref: "TimerCatch_1"},
      %SequenceFlow{id: "Flow_Timer_End", source_ref: "TimerCatch_1", target_ref: "End_1"}
    ]

    wrap_process(
      process_id,
      [start, parallel_gateway, task_a, task_b, event_based_gateway, timer_catch, end_event],
      flows
    )
  end

  @doc """
  Build a dead-end EventBasedGateway (0 outgoing flows) — handler should reject.

  Start_1 → EBG_1 (no outgoing)
  End_1 (unreachable)
  """
  def event_based_gateway_dead_end_process(opts \\ []) do
    process_id = Keyword.get(opts, :process_id, "test-process")

    start = %FlowNode{
      id: "Start_1",
      type: :start_event,
      type_data: %FlowNodeData.StartEvent{event_definition: %EventDefinition.None{}},
      outgoing: ["Flow_1"]
    }

    event_based_gateway = %FlowNode{
      id: "EBG_1",
      name: "Dead End EBG",
      type: :event_based_gateway,
      type_data: %FlowNodeData.EventBasedGateway{},
      incoming: ["Flow_1"],
      outgoing: []
    }

    end_event = %FlowNode{
      id: "End_1",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
      incoming: []
    }

    flows = [
      %SequenceFlow{id: "Flow_1", source_ref: "Start_1", target_ref: "EBG_1"}
    ]

    wrap_process(process_id, [start, event_based_gateway, end_event], flows)
  end

  @doc """
  Build Start → ParallelGateway(fork) → Task_A + Task_B + Task_C → ParallelGateway(join) → End.
  Three-branch parallel fork-join for resume mid-join and multi-branch merge testing.
  """
  def parallel_fork_join_three_branches(process_id \\ "test-process") do
    start = %FlowNode{
      id: "Start_1",
      type: :start_event,
      type_data: %FlowNodeData.StartEvent{event_definition: %EventDefinition.None{}},
      outgoing: ["Flow_1"]
    }

    fork = %FlowNode{
      id: "Fork_1",
      name: "Fork",
      type: :parallel_gateway,
      type_data: %FlowNodeData.ParallelGateway{},
      incoming: ["Flow_1"],
      outgoing: ["Flow_A", "Flow_B", "Flow_C"]
    }

    task_a = %FlowNode{
      id: "Task_A",
      name: "Task A",
      type: :task,
      type_data: %FlowNodeData.Task{},
      incoming: ["Flow_A"],
      outgoing: ["Flow_A2"]
    }

    task_b = %FlowNode{
      id: "Task_B",
      name: "Task B",
      type: :task,
      type_data: %FlowNodeData.Task{},
      incoming: ["Flow_B"],
      outgoing: ["Flow_B2"]
    }

    task_c = %FlowNode{
      id: "Task_C",
      name: "Task C",
      type: :task,
      type_data: %FlowNodeData.Task{},
      incoming: ["Flow_C"],
      outgoing: ["Flow_C2"]
    }

    join = %FlowNode{
      id: "Join_1",
      name: "Join",
      type: :parallel_gateway,
      type_data: %FlowNodeData.ParallelGateway{},
      incoming: ["Flow_A2", "Flow_B2", "Flow_C2"],
      outgoing: ["Flow_Join"]
    }

    end_event = %FlowNode{
      id: "End_1",
      name: "Done",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
      incoming: ["Flow_Join"]
    }

    flows = [
      %SequenceFlow{id: "Flow_1", source_ref: "Start_1", target_ref: "Fork_1"},
      %SequenceFlow{id: "Flow_A", source_ref: "Fork_1", target_ref: "Task_A"},
      %SequenceFlow{id: "Flow_B", source_ref: "Fork_1", target_ref: "Task_B"},
      %SequenceFlow{id: "Flow_C", source_ref: "Fork_1", target_ref: "Task_C"},
      %SequenceFlow{id: "Flow_A2", source_ref: "Task_A", target_ref: "Join_1"},
      %SequenceFlow{id: "Flow_B2", source_ref: "Task_B", target_ref: "Join_1"},
      %SequenceFlow{id: "Flow_C2", source_ref: "Task_C", target_ref: "Join_1"},
      %SequenceFlow{id: "Flow_Join", source_ref: "Join_1", target_ref: "End_1"}
    ]

    wrap_process(
      process_id,
      [start, fork, task_a, task_b, task_c, join, end_event],
      flows
    )
  end

  @doc """
  Build Start → Fork → ScriptTask_A (adds key_a) + ScriptTask_B (adds key_b) → Join → End.
  Tests payload merge: each branch adds a different key.
  """
  def parallel_gateway_payload_merge(process_id \\ "test-process") do
    start = %FlowNode{
      id: "Start_1",
      type: :start_event,
      type_data: %FlowNodeData.StartEvent{event_definition: %EventDefinition.None{}},
      outgoing: ["Flow_1"]
    }

    fork = %FlowNode{
      id: "Fork_1",
      name: "Fork",
      type: :parallel_gateway,
      type_data: %FlowNodeData.ParallelGateway{},
      incoming: ["Flow_1"],
      outgoing: ["Flow_A", "Flow_B"]
    }

    script_a = %FlowNode{
      id: "ScriptTask_A",
      name: "Add key_a",
      type: :script_task,
      type_data: %FlowNodeData.ScriptTask{
        script_format: "feel",
        script: ~s|{"key_a": "value_a"}|
      },
      incoming: ["Flow_A"],
      outgoing: ["Flow_A2"]
    }

    script_b = %FlowNode{
      id: "ScriptTask_B",
      name: "Add key_b",
      type: :script_task,
      type_data: %FlowNodeData.ScriptTask{
        script_format: "feel",
        script: ~s|{"key_b": "value_b"}|
      },
      incoming: ["Flow_B"],
      outgoing: ["Flow_B2"]
    }

    join = %FlowNode{
      id: "Join_1",
      name: "Join",
      type: :parallel_gateway,
      type_data: %FlowNodeData.ParallelGateway{},
      incoming: ["Flow_A2", "Flow_B2"],
      outgoing: ["Flow_Join"]
    }

    end_event = %FlowNode{
      id: "End_1",
      name: "Done",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
      incoming: ["Flow_Join"]
    }

    flows = [
      %SequenceFlow{id: "Flow_1", source_ref: "Start_1", target_ref: "Fork_1"},
      %SequenceFlow{id: "Flow_A", source_ref: "Fork_1", target_ref: "ScriptTask_A"},
      %SequenceFlow{id: "Flow_B", source_ref: "Fork_1", target_ref: "ScriptTask_B"},
      %SequenceFlow{id: "Flow_A2", source_ref: "ScriptTask_A", target_ref: "Join_1"},
      %SequenceFlow{id: "Flow_B2", source_ref: "ScriptTask_B", target_ref: "Join_1"},
      %SequenceFlow{id: "Flow_Join", source_ref: "Join_1", target_ref: "End_1"}
    ]

    wrap_process(
      process_id,
      [start, fork, script_a, script_b, join, end_event],
      flows
    )
  end

  @doc """
  Build nested fork-join: Outer Fork → (Inner Fork → Task_A1 + Task_A2 → Inner Join) + Task_B → Outer Join → End.
  """
  def parallel_gateway_nested(process_id \\ "test-process") do
    start = %FlowNode{
      id: "Start_1",
      type: :start_event,
      type_data: %FlowNodeData.StartEvent{event_definition: %EventDefinition.None{}},
      outgoing: ["Flow_1"]
    }

    outer_fork = %FlowNode{
      id: "OuterFork",
      name: "Outer Fork",
      type: :parallel_gateway,
      type_data: %FlowNodeData.ParallelGateway{},
      incoming: ["Flow_1"],
      outgoing: ["Flow_Inner", "Flow_B"]
    }

    inner_fork = %FlowNode{
      id: "InnerFork",
      name: "Inner Fork",
      type: :parallel_gateway,
      type_data: %FlowNodeData.ParallelGateway{},
      incoming: ["Flow_Inner"],
      outgoing: ["Flow_A1", "Flow_A2"]
    }

    task_a1 = %FlowNode{
      id: "Task_A1",
      name: "Task A1",
      type: :task,
      type_data: %FlowNodeData.Task{},
      incoming: ["Flow_A1"],
      outgoing: ["Flow_A1_Out"]
    }

    task_a2 = %FlowNode{
      id: "Task_A2",
      name: "Task A2",
      type: :task,
      type_data: %FlowNodeData.Task{},
      incoming: ["Flow_A2"],
      outgoing: ["Flow_A2_Out"]
    }

    inner_join = %FlowNode{
      id: "InnerJoin",
      name: "Inner Join",
      type: :parallel_gateway,
      type_data: %FlowNodeData.ParallelGateway{},
      incoming: ["Flow_A1_Out", "Flow_A2_Out"],
      outgoing: ["Flow_Inner_Out"]
    }

    task_b = %FlowNode{
      id: "Task_B",
      name: "Task B",
      type: :task,
      type_data: %FlowNodeData.Task{},
      incoming: ["Flow_B"],
      outgoing: ["Flow_B_Out"]
    }

    outer_join = %FlowNode{
      id: "OuterJoin",
      name: "Outer Join",
      type: :parallel_gateway,
      type_data: %FlowNodeData.ParallelGateway{},
      incoming: ["Flow_Inner_Out", "Flow_B_Out"],
      outgoing: ["Flow_Final"]
    }

    end_event = %FlowNode{
      id: "End_1",
      name: "Done",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
      incoming: ["Flow_Final"]
    }

    flows = [
      %SequenceFlow{id: "Flow_1", source_ref: "Start_1", target_ref: "OuterFork"},
      %SequenceFlow{id: "Flow_Inner", source_ref: "OuterFork", target_ref: "InnerFork"},
      %SequenceFlow{id: "Flow_B", source_ref: "OuterFork", target_ref: "Task_B"},
      %SequenceFlow{id: "Flow_A1", source_ref: "InnerFork", target_ref: "Task_A1"},
      %SequenceFlow{id: "Flow_A2", source_ref: "InnerFork", target_ref: "Task_A2"},
      %SequenceFlow{id: "Flow_A1_Out", source_ref: "Task_A1", target_ref: "InnerJoin"},
      %SequenceFlow{id: "Flow_A2_Out", source_ref: "Task_A2", target_ref: "InnerJoin"},
      %SequenceFlow{id: "Flow_Inner_Out", source_ref: "InnerJoin", target_ref: "OuterJoin"},
      %SequenceFlow{id: "Flow_B_Out", source_ref: "Task_B", target_ref: "OuterJoin"},
      %SequenceFlow{id: "Flow_Final", source_ref: "OuterJoin", target_ref: "End_1"}
    ]

    wrap_process(
      process_id,
      [
        start,
        outer_fork,
        inner_fork,
        task_a1,
        task_a2,
        inner_join,
        task_b,
        outer_join,
        end_event
      ],
      flows
    )
  end

  @doc """
  Build Start → ParallelGateway (mixed: 2 incoming, 2 outgoing) → ... → End.
  Used to test mixed gateway rejection at runtime.
  """
  def parallel_gateway_mixed(process_id \\ "test-process") do
    start = %FlowNode{
      id: "Start_1",
      type: :start_event,
      type_data: %FlowNodeData.StartEvent{event_definition: %EventDefinition.None{}},
      outgoing: ["Flow_1"]
    }

    task_before = %FlowNode{
      id: "Task_Before",
      name: "Before",
      type: :task,
      type_data: %FlowNodeData.Task{},
      incoming: ["Flow_1"],
      outgoing: ["Flow_Pre_A"]
    }

    mixed_gateway = %FlowNode{
      id: "Mixed_1",
      name: "Mixed",
      type: :parallel_gateway,
      type_data: %FlowNodeData.ParallelGateway{},
      incoming: ["Flow_Pre_A", "Flow_Pre_B"],
      outgoing: ["Flow_Out_A", "Flow_Out_B"]
    }

    task_a = %FlowNode{
      id: "Task_A",
      name: "Task A",
      type: :task,
      type_data: %FlowNodeData.Task{},
      incoming: ["Flow_Out_A"],
      outgoing: ["Flow_End_A"]
    }

    task_b = %FlowNode{
      id: "Task_B",
      name: "Task B",
      type: :task,
      type_data: %FlowNodeData.Task{},
      incoming: ["Flow_Out_B"],
      outgoing: ["Flow_End_B"]
    }

    end_event = %FlowNode{
      id: "End_1",
      name: "Done",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
      incoming: ["Flow_End_A", "Flow_End_B"]
    }

    flows = [
      %SequenceFlow{id: "Flow_1", source_ref: "Start_1", target_ref: "Task_Before"},
      %SequenceFlow{id: "Flow_Pre_A", source_ref: "Task_Before", target_ref: "Mixed_1"},
      %SequenceFlow{id: "Flow_Pre_B", source_ref: "Start_1", target_ref: "Mixed_1"},
      %SequenceFlow{id: "Flow_Out_A", source_ref: "Mixed_1", target_ref: "Task_A"},
      %SequenceFlow{id: "Flow_Out_B", source_ref: "Mixed_1", target_ref: "Task_B"},
      %SequenceFlow{id: "Flow_End_A", source_ref: "Task_A", target_ref: "End_1"},
      %SequenceFlow{id: "Flow_End_B", source_ref: "Task_B", target_ref: "End_1"}
    ]

    wrap_process(
      process_id,
      [start, task_before, mixed_gateway, task_a, task_b, end_event],
      flows
    )
  end

  @doc """
  Build Start → Fork → Task_A + Task_B → Join → Error End Event.
  Tests that join merges tokens, then error end event fires → PI :error state.
  """
  def parallel_fork_join_then_error_end(process_id \\ "test-process") do
    start = %FlowNode{
      id: "Start_1",
      type: :start_event,
      type_data: %FlowNodeData.StartEvent{event_definition: %EventDefinition.None{}},
      outgoing: ["Flow_1"]
    }

    fork = %FlowNode{
      id: "Fork_1",
      name: "Fork",
      type: :parallel_gateway,
      type_data: %FlowNodeData.ParallelGateway{},
      incoming: ["Flow_1"],
      outgoing: ["Flow_A", "Flow_B"]
    }

    task_a = %FlowNode{
      id: "Task_A",
      name: "Task A",
      type: :task,
      type_data: %FlowNodeData.Task{},
      incoming: ["Flow_A"],
      outgoing: ["Flow_A2"]
    }

    task_b = %FlowNode{
      id: "Task_B",
      name: "Task B",
      type: :task,
      type_data: %FlowNodeData.Task{},
      incoming: ["Flow_B"],
      outgoing: ["Flow_B2"]
    }

    join = %FlowNode{
      id: "Join_1",
      name: "Join",
      type: :parallel_gateway,
      type_data: %FlowNodeData.ParallelGateway{},
      incoming: ["Flow_A2", "Flow_B2"],
      outgoing: ["Flow_Join"]
    }

    error_end = %FlowNode{
      id: "End_Error",
      name: "Error End",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{
        event_definition: %EventDefinition.Error{
          error_ref: nil,
          error_code: "PARALLEL_JOIN_ERROR",
          error_message: "Error after parallel join"
        }
      },
      incoming: ["Flow_Join"]
    }

    flows = [
      %SequenceFlow{id: "Flow_1", source_ref: "Start_1", target_ref: "Fork_1"},
      %SequenceFlow{id: "Flow_A", source_ref: "Fork_1", target_ref: "Task_A"},
      %SequenceFlow{id: "Flow_B", source_ref: "Fork_1", target_ref: "Task_B"},
      %SequenceFlow{id: "Flow_A2", source_ref: "Task_A", target_ref: "Join_1"},
      %SequenceFlow{id: "Flow_B2", source_ref: "Task_B", target_ref: "Join_1"},
      %SequenceFlow{id: "Flow_Join", source_ref: "Join_1", target_ref: "End_Error"}
    ]

    wrap_process(
      process_id,
      [start, fork, task_a, task_b, join, error_end],
      flows
    )
  end

  @doc """
  Build Start → Fork → Task_A → Terminate End + UserTask_B → End.
  One branch auto-completes and terminates, other has a UserTask.
  Alias for `parallel_with_terminate_end_event/1`.
  """
  def parallel_fork_with_terminate(process_id \\ "test-process") do
    parallel_with_terminate_end_event(process_id)
  end

  @doc """
  Build Start → Fork → UserTask_A + UserTask_B → Join → End.
  Both branches are UserTasks (wait for completion), used for lifecycle edge-case tests.
  """
  def parallel_fork_join_user_tasks(process_id \\ "test-process") do
    start = %FlowNode{
      id: "Start_1",
      type: :start_event,
      type_data: %FlowNodeData.StartEvent{event_definition: %EventDefinition.None{}},
      outgoing: ["Flow_1"]
    }

    fork = %FlowNode{
      id: "Fork_1",
      name: "Fork",
      type: :parallel_gateway,
      type_data: %FlowNodeData.ParallelGateway{},
      incoming: ["Flow_1"],
      outgoing: ["Flow_A", "Flow_B"]
    }

    user_task_a = %FlowNode{
      id: "UserTask_A",
      name: "User Task A",
      type: :user_task,
      type_data: %FlowNodeData.UserTask{form_schema: %{"fields" => []}},
      incoming: ["Flow_A"],
      outgoing: ["Flow_A2"]
    }

    user_task_b = %FlowNode{
      id: "UserTask_B",
      name: "User Task B",
      type: :user_task,
      type_data: %FlowNodeData.UserTask{form_schema: %{"fields" => []}},
      incoming: ["Flow_B"],
      outgoing: ["Flow_B2"]
    }

    join = %FlowNode{
      id: "Join_1",
      name: "Join",
      type: :parallel_gateway,
      type_data: %FlowNodeData.ParallelGateway{},
      incoming: ["Flow_A2", "Flow_B2"],
      outgoing: ["Flow_Join"]
    }

    end_event = %FlowNode{
      id: "End_1",
      name: "Done",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
      incoming: ["Flow_Join"]
    }

    flows = [
      %SequenceFlow{id: "Flow_1", source_ref: "Start_1", target_ref: "Fork_1"},
      %SequenceFlow{id: "Flow_A", source_ref: "Fork_1", target_ref: "UserTask_A"},
      %SequenceFlow{id: "Flow_B", source_ref: "Fork_1", target_ref: "UserTask_B"},
      %SequenceFlow{id: "Flow_A2", source_ref: "UserTask_A", target_ref: "Join_1"},
      %SequenceFlow{id: "Flow_B2", source_ref: "UserTask_B", target_ref: "Join_1"},
      %SequenceFlow{id: "Flow_Join", source_ref: "Join_1", target_ref: "End_1"}
    ]

    wrap_process(
      process_id,
      [start, fork, user_task_a, user_task_b, join, end_event],
      flows
    )
  end

  @doc """
  Build Start → Fork → Task_A + UserTask_B → Join → End.
  Task_A auto-completes, UserTask_B waits. Tests abort during join wait.
  """
  def parallel_fork_join_task_and_user_task(process_id \\ "test-process") do
    start = %FlowNode{
      id: "Start_1",
      type: :start_event,
      type_data: %FlowNodeData.StartEvent{event_definition: %EventDefinition.None{}},
      outgoing: ["Flow_1"]
    }

    fork = %FlowNode{
      id: "Fork_1",
      name: "Fork",
      type: :parallel_gateway,
      type_data: %FlowNodeData.ParallelGateway{},
      incoming: ["Flow_1"],
      outgoing: ["Flow_A", "Flow_B"]
    }

    task_a = %FlowNode{
      id: "Task_A",
      name: "Task A",
      type: :task,
      type_data: %FlowNodeData.Task{},
      incoming: ["Flow_A"],
      outgoing: ["Flow_A2"]
    }

    user_task_b = %FlowNode{
      id: "UserTask_B",
      name: "User Task B",
      type: :user_task,
      type_data: %FlowNodeData.UserTask{form_schema: %{"fields" => []}},
      incoming: ["Flow_B"],
      outgoing: ["Flow_B2"]
    }

    join = %FlowNode{
      id: "Join_1",
      name: "Join",
      type: :parallel_gateway,
      type_data: %FlowNodeData.ParallelGateway{},
      incoming: ["Flow_A2", "Flow_B2"],
      outgoing: ["Flow_Join"]
    }

    end_event = %FlowNode{
      id: "End_1",
      name: "Done",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
      incoming: ["Flow_Join"]
    }

    flows = [
      %SequenceFlow{id: "Flow_1", source_ref: "Start_1", target_ref: "Fork_1"},
      %SequenceFlow{id: "Flow_A", source_ref: "Fork_1", target_ref: "Task_A"},
      %SequenceFlow{id: "Flow_B", source_ref: "Fork_1", target_ref: "UserTask_B"},
      %SequenceFlow{id: "Flow_A2", source_ref: "Task_A", target_ref: "Join_1"},
      %SequenceFlow{id: "Flow_B2", source_ref: "UserTask_B", target_ref: "Join_1"},
      %SequenceFlow{id: "Flow_Join", source_ref: "Join_1", target_ref: "End_1"}
    ]

    wrap_process(
      process_id,
      [start, fork, task_a, user_task_b, join, end_event],
      flows
    )
  end

  @doc """
  Fork → Task_A (completes) + ServiceTask_B (unregistered implementation → fatal) → Join → End.
  Tests 9c: one branch fatals before reaching the join.
  """
  def parallel_fork_join_with_fatal_branch(process_id \\ "test-process") do
    start = %FlowNode{
      id: "Start_1",
      type: :start_event,
      type_data: %FlowNodeData.StartEvent{event_definition: %EventDefinition.None{}},
      outgoing: ["Flow_1"]
    }

    fork = %FlowNode{
      id: "Fork_1",
      name: "Fork",
      type: :parallel_gateway,
      type_data: %FlowNodeData.ParallelGateway{},
      incoming: ["Flow_1"],
      outgoing: ["Flow_A", "Flow_B"]
    }

    task_a = %FlowNode{
      id: "Task_A",
      name: "Task A",
      type: :task,
      type_data: %FlowNodeData.Task{},
      incoming: ["Flow_A"],
      outgoing: ["Flow_A2"]
    }

    service_task_b = %FlowNode{
      id: "ServiceTask_B",
      name: "Service Task B (fails)",
      type: :service_task,
      type_data: %FlowNodeData.ServiceTask{implementation: "nonexistent_handler_xyz"},
      incoming: ["Flow_B"],
      outgoing: ["Flow_B2"]
    }

    join = %FlowNode{
      id: "Join_1",
      name: "Join",
      type: :parallel_gateway,
      type_data: %FlowNodeData.ParallelGateway{},
      incoming: ["Flow_A2", "Flow_B2"],
      outgoing: ["Flow_Join"]
    }

    end_event = %FlowNode{
      id: "End_1",
      name: "Done",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
      incoming: ["Flow_Join"]
    }

    flows = [
      %SequenceFlow{id: "Flow_1", source_ref: "Start_1", target_ref: "Fork_1"},
      %SequenceFlow{id: "Flow_A", source_ref: "Fork_1", target_ref: "Task_A"},
      %SequenceFlow{id: "Flow_B", source_ref: "Fork_1", target_ref: "ServiceTask_B"},
      %SequenceFlow{id: "Flow_A2", source_ref: "Task_A", target_ref: "Join_1"},
      %SequenceFlow{id: "Flow_B2", source_ref: "ServiceTask_B", target_ref: "Join_1"},
      %SequenceFlow{id: "Flow_Join", source_ref: "Join_1", target_ref: "End_1"}
    ]

    wrap_process(
      process_id,
      [start, fork, task_a, service_task_b, join, end_event],
      flows
    )
  end

  @doc """
  Start → sequential ad-hoc subprocess with three inner user tasks.

  `bfw:activeElements` lists Task_C then Task_A so list order differs
  from inner-activity model order (A, B, C).
  """
  def sequential_adhoc_user_tasks(opts \\ []) do
    process_id = Keyword.get(opts, :process_id, "test-process")

    active_elements =
      Keyword.get(opts, :active_elements_expression, ~s(["Task_C", "Task_A"]))

    ordering = Keyword.get(opts, :adhoc_ordering, :sequential)

    task_a = %FlowNode{
      id: "Task_A",
      name: "Task A",
      type: :user_task,
      type_data: %FlowNodeData.UserTask{form_schema: %{"fields" => []}}
    }

    task_b = %FlowNode{
      id: "Task_B",
      name: "Task B",
      type: :user_task,
      type_data: %FlowNodeData.UserTask{form_schema: %{"fields" => []}}
    }

    task_c = %FlowNode{
      id: "Task_C",
      name: "Task C",
      type: :user_task,
      type_data: %FlowNodeData.UserTask{form_schema: %{"fields" => []}}
    }

    start = %FlowNode{
      id: "Start_1",
      type: :start_event,
      type_data: %FlowNodeData.StartEvent{event_definition: %EventDefinition.None{}},
      outgoing: ["Flow_1"]
    }

    adhoc = %FlowNode{
      id: "AdHoc_1",
      name: "Sequential Ad-hoc",
      type: :sub_process,
      type_data: %FlowNodeData.SubProcess{
        is_ad_hoc: true,
        adhoc_ordering: ordering,
        cancel_remaining_instances: true,
        active_elements_expression: active_elements,
        flow_nodes: [task_a, task_b, task_c],
        sequence_flows: []
      },
      incoming: ["Flow_1"],
      outgoing: ["Flow_2"]
    }

    end_event = %FlowNode{
      id: "End_1",
      name: "Done",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
      incoming: ["Flow_2"]
    }

    flows = [
      %SequenceFlow{id: "Flow_1", source_ref: "Start_1", target_ref: "AdHoc_1"},
      %SequenceFlow{id: "Flow_2", source_ref: "AdHoc_1", target_ref: "End_1"}
    ]

    wrap_process(process_id, [start, adhoc, end_event], flows)
  end
end
