defmodule EvilEngine.BPMN.Model.Process do
  @moduledoc """
  A single `<bpmn:process>` inside a BPMN definitions document.

  `version` is read from the mandatory `<evil:version>` extension.
  """

  alias EvilEngine.BPMN.InclusiveJoinAnalysis
  alias EvilEngine.BPMN.Model.DataObject
  alias EvilEngine.BPMN.Model.DataObjectReference
  alias EvilEngine.BPMN.Model.Extension
  alias EvilEngine.BPMN.Model.FlowNode
  alias EvilEngine.BPMN.Model.Lane
  alias EvilEngine.BPMN.Model.LinterRulesetScore
  alias EvilEngine.BPMN.Model.SequenceFlow

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t() | nil,
          version: String.t() | nil,
          is_executable: boolean(),
          flow_nodes: [FlowNode.t()],
          sequence_flows: [SequenceFlow.t()],
          lanes: [Lane.t()],
          data_objects: [DataObject.t()],
          data_object_references: [DataObjectReference.t()],
          extensions: [Extension.t()],
          linter_scores: [LinterRulesetScore.t()],
          correlation_key: String.t() | nil,
          inclusive_join_analyses: %{String.t() => InclusiveJoinAnalysis.t()}
        }

  @enforce_keys [:id]
  defstruct [
    :id,
    :name,
    :version,
    :correlation_key,
    is_executable: true,
    flow_nodes: [],
    sequence_flows: [],
    lanes: [],
    data_objects: [],
    data_object_references: [],
    extensions: [],
    linter_scores: [],
    inclusive_join_analyses: %{}
  ]
end
