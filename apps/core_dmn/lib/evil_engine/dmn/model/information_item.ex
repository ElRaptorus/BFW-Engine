defmodule EvilEngine.DMN.Model.InformationItem do
  @moduledoc """
  A named, optionally typed variable declaration in a DMN model.

  Used as the `variable` on Decisions, BKMs, and InputData, and as
  `formalParameter` entries inside `FunctionDefinition`.
  """

  @type t :: %__MODULE__{
          id: String.t() | nil,
          name: String.t(),
          type_ref: String.t() | nil
        }

  @enforce_keys [:name]
  defstruct [:id, :name, :type_ref]
end
