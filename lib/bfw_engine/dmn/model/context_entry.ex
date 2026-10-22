defmodule BfwEngine.DMN.Model.ContextEntry do
  @moduledoc """
  A single entry within a `BoxedContext`.

  Binds `variable` (an `InformationItem`) to the evaluated value of
  `expression`. If `variable` is nil, the entry is the "result expression"
  of the enclosing context.
  """

  alias BfwEngine.DMN.Model.InformationItem
  alias BfwEngine.DMN.Model.Types

  @type t :: %__MODULE__{
          variable: InformationItem.t() | nil,
          expression: Types.expression_body() | nil
        }

  defstruct [:variable, :expression]
end
