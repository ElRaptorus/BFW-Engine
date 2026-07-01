defmodule EvilEngine.DMN.Model.FunctionDefinition do
  @moduledoc """
  Encapsulated logic inside a BusinessKnowledgeModel.

  Contains a list of `formal_parameters` (InformationItems) and a
  `body` holding one of the `Types.expression_body()` variants.

  The `type` is always `:feel` in CL1 — Java and PMML function
  types are parsed but rejected by the validator.
  """

  alias EvilEngine.DMN.Model.InformationItem
  alias EvilEngine.DMN.Model.Types

  @type function_type :: :feel | :java | :pmml | :unsupported

  @type t :: %__MODULE__{
          id: String.t() | nil,
          type: function_type(),
          formal_parameters: [InformationItem.t()],
          body: Types.expression_body() | nil
        }

  defstruct [:id, :body, type: :feel, formal_parameters: []]
end
