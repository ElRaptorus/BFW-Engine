defmodule BfwEngine.DMN.Model.KnowledgeRequirement do
  @moduledoc """
  A DRG edge linking a Decision or BKM to a required BKM (G3).

  The `required_knowledge_id` references the `id` of the target
  `BusinessKnowledgeModel`, indicating that the parent element
  invokes the BKM during evaluation.
  """

  @type t :: %__MODULE__{
          id: String.t() | nil,
          required_knowledge_id: String.t()
        }

  @enforce_keys [:required_knowledge_id]
  defstruct [:id, :required_knowledge_id]
end
