defmodule EvilEngine.DMN.Model.BoxedList do
  @moduledoc """
  A boxed list expression (DMN CL3).

  Contains an ordered collection of sub-expressions. Each element is
  evaluated independently and the results form a FEEL list.
  """

  alias EvilEngine.DMN.Model.Types

  @type t :: %__MODULE__{
          id: String.t() | nil,
          elements: [Types.expression_body()]
        }

  defstruct [:id, elements: []]
end
