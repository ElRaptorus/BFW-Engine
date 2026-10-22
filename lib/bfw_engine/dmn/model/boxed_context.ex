defmodule BfwEngine.DMN.Model.BoxedContext do
  @moduledoc """
  A boxed context expression (DMN CL3).

  Contains a list of context entries, each binding a variable name to an
  expression. Entries are evaluated sequentially — later entries can
  reference variables defined by earlier ones. The final entry may omit
  its variable, in which case its expression value becomes the overall
  result of the context.
  """

  alias BfwEngine.DMN.Model.ContextEntry

  @type t :: %__MODULE__{
          id: String.t() | nil,
          context_entries: [ContextEntry.t()]
        }

  defstruct [:id, context_entries: []]
end
