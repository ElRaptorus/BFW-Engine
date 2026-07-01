defmodule EvilEngine.DMN.Model.Relation do
  @moduledoc """
  A relation expression (DMN CL3).

  Tabular data represented as named columns and rows of expressions.
  Evaluates to a list of contexts — each row maps column names to
  evaluated cell expression values.
  """

  alias EvilEngine.DMN.Model.InformationItem
  alias EvilEngine.DMN.Model.Types

  @type t :: %__MODULE__{
          id: String.t() | nil,
          columns: [InformationItem.t()],
          rows: [[Types.expression_body()]]
        }

  defstruct [:id, columns: [], rows: []]
end
