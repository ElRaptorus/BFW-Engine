defmodule BfwEngine.DMN.Model.LiteralExpression do
  @moduledoc """
  A standalone FEEL expression as a Decision's value expression (G8).

  The most common non-table expression type in real DMN models.
  Contains a single FEEL expression in `text` that is evaluated
  directly against the input context.
  """

  @type t :: %__MODULE__{
          id: String.t() | nil,
          text: String.t(),
          type_ref: String.t() | nil,
          expression_language: String.t() | nil,
          compiled_ref: reference() | nil
        }

  @enforce_keys [:text]
  defstruct [:id, :text, :type_ref, :expression_language, compiled_ref: nil]
end
