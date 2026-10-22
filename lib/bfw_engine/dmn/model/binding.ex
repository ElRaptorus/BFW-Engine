defmodule BfwEngine.DMN.Model.Binding do
  @moduledoc """
  A parameter binding within a `BoxedInvocation`.

  Maps `parameter` (an `InformationItem` with the formal parameter name)
  to `expression`, whose evaluated value becomes the argument.
  """

  alias BfwEngine.DMN.Model.InformationItem
  alias BfwEngine.DMN.Model.Types

  @type t :: %__MODULE__{
          parameter: InformationItem.t() | nil,
          expression: Types.expression_body() | nil
        }

  defstruct [:parameter, :expression]
end
