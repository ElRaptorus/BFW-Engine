defmodule EvilEngine.DMN.Model.BoxedInvocation do
  @moduledoc """
  A boxed invocation expression (DMN CL3).

  Invokes a BKM or function by name (`called_function`), passing named
  parameter bindings. Each binding maps a formal parameter name to an
  expression whose evaluated value becomes the argument.
  """

  alias EvilEngine.DMN.Model.Binding

  @type t :: %__MODULE__{
          id: String.t() | nil,
          called_function: String.t() | nil,
          bindings: [Binding.t()]
        }

  defstruct [:id, :called_function, bindings: []]
end
