defmodule EvilEngine.DMN.Model.InformationRequirement do
  @moduledoc """
  A DRG information requirement linking a decision to its inputs.

  Either `required_decision_id` or `required_input_id` is set, never both.
  Used for DRD chaining in Phase 4; parsed and preserved in Phase 3.
  """

  @type t :: %__MODULE__{
          id: String.t() | nil,
          required_decision_id: String.t() | nil,
          required_input_id: String.t() | nil
        }

  defstruct [:id, :required_decision_id, :required_input_id]
end
