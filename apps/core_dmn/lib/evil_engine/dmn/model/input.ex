defmodule EvilEngine.DMN.Model.Input do
  @moduledoc "A column header in a DMN decision table."

  @type t :: %__MODULE__{
          id: String.t(),
          label: String.t() | nil,
          input_expression: String.t() | nil,
          input_values: String.t() | nil,
          type_ref: String.t() | nil,
          compiled_expression_ref: reference() | nil,
          compiled_input_values_ref: reference() | nil
        }

  @enforce_keys [:id]
  defstruct [
    :id,
    :label,
    :input_expression,
    :input_values,
    :type_ref,
    compiled_expression_ref: nil,
    compiled_input_values_ref: nil
  ]
end
