defmodule EvilEngine.BPMN.Model.SequenceFlow do
  @moduledoc """
  A `<bpmn:sequenceFlow>` connecting two flow nodes.

  `condition_expression` holds the FEEL expression text from
  `<bpmn:conditionExpression>` (nil for unconditional flows).
  """

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t() | nil,
          source_ref: String.t(),
          target_ref: String.t(),
          condition_expression: String.t() | nil,
          is_default: boolean()
        }

  @enforce_keys [:id, :source_ref, :target_ref]
  defstruct [:id, :name, :source_ref, :target_ref, :condition_expression, is_default: false]
end
