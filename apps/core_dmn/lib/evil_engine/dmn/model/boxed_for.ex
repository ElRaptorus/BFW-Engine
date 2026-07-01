defmodule EvilEngine.DMN.Model.BoxedFor do
  @moduledoc """
  A boxed for-loop expression (DMN 1.4+, CL3).

  Iterates over `in_expression` (must evaluate to a list), binding each
  element to `iterator_variable`, evaluating `return_expression`, and
  collecting the results into a new list.
  """

  alias EvilEngine.DMN.Model.Types

  @type t :: %__MODULE__{
          id: String.t() | nil,
          iterator_variable: String.t() | nil,
          in_expression: Types.expression_body() | nil,
          return_expression: Types.expression_body() | nil
        }

  defstruct [:id, :iterator_variable, :in_expression, :return_expression]
end
