defmodule BfwEngine.DMN.Model.Output do
  @moduledoc "An output column in a DMN decision table."

  @type t :: %__MODULE__{
          id: String.t(),
          label: String.t() | nil,
          name: String.t() | nil,
          output_values: String.t() | nil,
          type_ref: String.t() | nil,
          default_output_value: String.t() | nil,
          compiled_default_ref: reference() | nil
        }

  @enforce_keys [:id]
  defstruct [:id, :label, :name, :output_values, :type_ref, :default_output_value, :compiled_default_ref]
end
