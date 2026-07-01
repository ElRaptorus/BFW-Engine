defmodule EvilEngine.DMN.Model.BusinessKnowledgeModel do
  @moduledoc """
  A reusable piece of business logic in the DRG (G2).

  A BKM contains an `encapsulated_logic` (`FunctionDefinition`)
  with formal parameters and a body (DecisionTable or
  LiteralExpression). Decisions and other BKMs reference it via
  `KnowledgeRequirement` edges.

  The optional `variable` (InformationItem) declares the BKM's
  output name and type for DRD context binding.
  """

  alias EvilEngine.DMN.Model.AuthorityRequirement
  alias EvilEngine.DMN.Model.FunctionDefinition
  alias EvilEngine.DMN.Model.InformationItem
  alias EvilEngine.DMN.Model.KnowledgeRequirement

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t() | nil,
          encapsulated_logic: FunctionDefinition.t() | nil,
          knowledge_requirements: [KnowledgeRequirement.t()],
          authority_requirements: [AuthorityRequirement.t()],
          variable: InformationItem.t() | nil
        }

  @enforce_keys [:id]
  defstruct [:id, :name, :encapsulated_logic, :variable,
             knowledge_requirements: [], authority_requirements: []]
end
