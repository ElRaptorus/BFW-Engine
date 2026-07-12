defmodule EvilEngine.BPMN.Model.Process do
  @moduledoc """
  A single `<bpmn:process>` inside a BPMN definitions document.

  `version` is read from the mandatory `<evil:version>` extension.
  """

  alias EvilEngine.BPMN.ComplexRegionAnalysis
  alias EvilEngine.BPMN.InclusiveJoinAnalysis
  alias EvilEngine.BPMN.Model.Association
  alias EvilEngine.BPMN.Model.DataObject
  alias EvilEngine.BPMN.Model.DataObjectReference
  alias EvilEngine.BPMN.Model.Extension
  alias EvilEngine.BPMN.Model.FlowNode
  alias EvilEngine.BPMN.Model.Lane
  alias EvilEngine.BPMN.Model.SequenceFlow

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t() | nil,
          version: String.t() | nil,
          is_executable: boolean(),
          is_transaction_scope: boolean(),
          flow_nodes: [FlowNode.t()],
          sequence_flows: [SequenceFlow.t()],
          lanes: [Lane.t()],
          data_objects: [DataObject.t()],
          data_object_references: [DataObjectReference.t()],
          associations: [Association.t()],
          extensions: [Extension.t()],
          correlation_key: String.t() | nil,
          inclusive_join_analyses: %{String.t() => InclusiveJoinAnalysis.t()},
          complex_region_analyses: %{String.t() => ComplexRegionAnalysis.t()}
        }

  @enforce_keys [:id]
  defstruct [
    :id,
    :name,
    :version,
    :correlation_key,
    is_executable: true,
    is_transaction_scope: false,
    flow_nodes: [],
    sequence_flows: [],
    lanes: [],
    data_objects: [],
    data_object_references: [],
    associations: [],
    extensions: [],
    inclusive_join_analyses: %{},
    complex_region_analyses: %{}
  ]
end
