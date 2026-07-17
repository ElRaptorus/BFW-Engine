defmodule EvilEngine.BPMN.Precompiler do
  @moduledoc """
  Structural precompilation pass for parsed BPMN model structs.

  Called after parse+validate, before the `Definitions` struct is placed
  into the ModelCache. Walks the flow-node tree so that future
  precompilation hooks (e.g. condition expressions) have a single
  traversal point.

  MI and Standard Loop FEEL expressions (`collection_expression`,
  `loop_condition`, `completion_condition`, `loop_break_condition`,
  `output_collection`) are intentionally **not** precompiled. They
  reference runtime context variables (`token.*`, `loop.*`) whose
  shape is unknown at deploy time. The Rust NIF requires a matching
  context shape at compile time — expressions compiled without it
  silently evaluate to `nil` at runtime. The handlers always use
  `Expressions.eval/2` (one-shot parse+evaluate). The performance
  cost is negligible since these expressions are evaluated at most a
  handful of times per PI.
  """

  alias EvilEngine.BPMN.Model.Definitions
  alias EvilEngine.BPMN.Model.FlowNode
  alias EvilEngine.BPMN.Model.FlowNodeData
  alias EvilEngine.BPMN.Model.Process, as: BpmnProcess

  @doc """
  Walks the definitions tree and precompiles FEEL expressions on all
  flow nodes. Currently a structural pass only — MI and Standard Loop
  expressions are intentionally left uncompiled (see moduledoc).
  Returns the updated `%Definitions{}`.
  """
  @spec precompile(Definitions.t()) :: Definitions.t()
  def precompile(%Definitions{} = definitions) do
    processes = Enum.map(definitions.processes, &precompile_process/1)
    %{definitions | processes: processes}
  end

  defp precompile_process(%BpmnProcess{} = process) do
    flow_nodes = Enum.map(process.flow_nodes, &precompile_flow_node/1)
    %{process | flow_nodes: flow_nodes}
  end

  defp precompile_flow_node(%FlowNode{} = node) do
    precompile_subprocess_children(node)
  end

  defp precompile_subprocess_children(
         %FlowNode{type_data: %FlowNodeData.SubProcess{} = sp_data} = node
       ) do
    inner_flow_nodes = Enum.map(sp_data.flow_nodes, &precompile_flow_node/1)
    %{node | type_data: %{sp_data | flow_nodes: inner_flow_nodes}}
  end

  defp precompile_subprocess_children(node), do: node
end
