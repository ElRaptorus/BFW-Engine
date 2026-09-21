defmodule BfwEngine.DMN.Model.BoxedConditional do
  @moduledoc """
  A boxed conditional expression (DMN 1.4+, CL3).

  Classic if/then/else branching. `if_expression` is evaluated first;
  if truthy, `then_expression` is evaluated and returned, otherwise
  `else_expression` is evaluated and returned.
  """

  alias BfwEngine.DMN.Model.Types

  @type t :: %__MODULE__{
          id: String.t() | nil,
          if_expression: Types.expression_body() | nil,
          then_expression: Types.expression_body() | nil,
          else_expression: Types.expression_body() | nil
        }

  defstruct [:id, :if_expression, :then_expression, :else_expression]
end
