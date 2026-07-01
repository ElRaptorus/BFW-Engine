defmodule EvilEngine.DMN.Model.DecisionService do
  @moduledoc """
  Represents a `<decisionService>` element in DMN.

  A Decision Service defines a well-defined boundary around a set of
  decisions within a DRG. It exposes output decisions to callers while
  encapsulating internal implementation decisions.

  All ID lists (`output_decisions`, `encapsulated_decisions`,
  `input_decisions`, `input_data`) store decision/input-data element IDs
  extracted from `href` attributes in the XML.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t() | nil,
          output_decisions: [String.t()],
          encapsulated_decisions: [String.t()],
          input_decisions: [String.t()],
          input_data: [String.t()]
        }

  defstruct [:id, :name,
             output_decisions: [],
             encapsulated_decisions: [],
             input_decisions: [],
             input_data: []]
end
