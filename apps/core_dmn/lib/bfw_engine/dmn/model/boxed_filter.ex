defmodule BfwEngine.DMN.Model.BoxedFilter do
  @moduledoc """
  A boxed filter expression (DMN 1.4+, CL3).

  Filters a list: `in_expression` must evaluate to a list, and for
  each element, `match_expression` is evaluated with the element bound
  as `item`. Elements where the match is truthy are included in the
  result list.
  """

  alias BfwEngine.DMN.Model.Types

  @type t :: %__MODULE__{
          id: String.t() | nil,
          in_expression: Types.expression_body() | nil,
          match_expression: Types.expression_body() | nil
        }

  defstruct [:id, :in_expression, :match_expression]
end
