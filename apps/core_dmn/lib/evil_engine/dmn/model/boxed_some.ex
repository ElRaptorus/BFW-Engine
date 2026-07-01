defmodule EvilEngine.DMN.Model.BoxedSome do
  @moduledoc """
  A boxed "some" quantifier expression (DMN 1.4+, CL3).

  Existential quantifier: iterates over `in_expression` (a list),
  binds each element to `iterator_variable`, evaluates
  `satisfies_expression` — returns `true` if at least one iteration
  satisfies the predicate.
  """

  alias EvilEngine.DMN.Model.Types

  @type t :: %__MODULE__{
          id: String.t() | nil,
          iterator_variable: String.t() | nil,
          in_expression: Types.expression_body() | nil,
          satisfies_expression: Types.expression_body() | nil
        }

  defstruct [:id, :iterator_variable, :in_expression, :satisfies_expression]
end
