defmodule EvilEngine.DMN.Model.InputData do
  @moduledoc "An input data element declared at the definitions level."

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          type_ref: String.t() | nil
        }

  @enforce_keys [:id, :name]
  defstruct [:id, :name, :type_ref]
end
