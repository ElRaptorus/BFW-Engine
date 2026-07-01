defmodule EvilEngine.DMN.Model.ItemDefinition do
  @moduledoc """
  A custom type declaration in a DMN model (G6).

  ItemDefinitions can be:
  - **Simple:** a `type_ref` referencing a FEEL built-in type
  - **Composite:** nested `item_components` forming a FEEL context type
  - **Collection:** `is_collection: true` wraps the type as a FEEL list
  - **Constrained:** `allowed_values` restricts the value space via a
    unary test expression
  """

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          type_ref: String.t() | nil,
          allowed_values: String.t() | nil,
          item_components: [t()],
          is_collection: boolean()
        }

  @enforce_keys [:id, :name]
  defstruct [:id, :name, :type_ref, :allowed_values,
             item_components: [], is_collection: false]
end
