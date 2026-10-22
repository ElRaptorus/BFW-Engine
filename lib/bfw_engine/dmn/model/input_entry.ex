defmodule BfwEngine.DMN.Model.InputEntry do
  @moduledoc """
  A cell in the input portion of a decision table rule.

  `text` contains a FEEL unary test expression (e.g. `> 100`, `"approved"`)
  or `-` for "any" (always matches).
  """

  @type t :: %__MODULE__{
          id: String.t(),
          text: String.t(),
          compiled_ref: reference() | nil
        }

  @enforce_keys [:id, :text]
  defstruct [:id, :text, compiled_ref: nil]
end
