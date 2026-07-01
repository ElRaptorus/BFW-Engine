defmodule EvilEngine.DMN.Model.AuthorityRequirement do
  @moduledoc """
  A non-executable DRG edge representing governance authority (G5).

  Links a Decision, BKM, or KnowledgeSource to one of:
  - a KnowledgeSource (`required_authority_id`)
  - a Decision (`required_decision_id`)
  - an InputData (`required_input_id`)

  These edges are parsed and preserved for DRD diagram fidelity but
  have zero runtime behavior — the evaluator ignores them.
  """

  @type t :: %__MODULE__{
          id: String.t() | nil,
          required_authority_id: String.t() | nil,
          required_decision_id: String.t() | nil,
          required_input_id: String.t() | nil
        }

  defstruct [:id, :required_authority_id, :required_decision_id, :required_input_id]
end
