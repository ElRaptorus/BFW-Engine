defmodule EvilEngine.DMN.Model.Rule do
  @moduledoc "A single row in a DMN decision table."

  alias EvilEngine.DMN.Model.InputEntry
  alias EvilEngine.DMN.Model.OutputEntry

  @type t :: %__MODULE__{
          id: String.t(),
          description: String.t() | nil,
          input_entries: [InputEntry.t()],
          output_entries: [OutputEntry.t()],
          annotation_entries: [String.t()]
        }

  @enforce_keys [:id]
  defstruct [:id, :description, input_entries: [], output_entries: [], annotation_entries: []]
end
