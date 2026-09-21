defmodule BfwEngine.DMN.Model.KnowledgeSource do
  @moduledoc """
  A non-executable documentation element representing an external
  authority in the DRG (G4).

  Knowledge sources are parsed and preserved for roundtrip
  serialization and DRD diagram fidelity, but the evaluator
  ignores them entirely. They exist for governance documentation
  only.
  """

  alias BfwEngine.DMN.Model.AuthorityRequirement

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t() | nil,
          type: String.t() | nil,
          authority_requirements: [AuthorityRequirement.t()]
        }

  @enforce_keys [:id]
  defstruct [:id, :name, :type, authority_requirements: []]
end
