defmodule BfwEngine.DMN.Model.OutputEntry do
  @moduledoc """
  A cell in the output portion of a decision table rule.

  `text` contains a FEEL expression that produces the output value.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          text: String.t(),
          compiled_ref: reference() | nil
        }

  @enforce_keys [:id, :text]
  defstruct [:id, :text, compiled_ref: nil]
end
