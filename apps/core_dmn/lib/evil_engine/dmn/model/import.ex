defmodule EvilEngine.DMN.Model.Import do
  @moduledoc """
  A cross-model import declaration in a DMN model (G7).

  Allows one DMN Definitions to reference decisions, BKMs, and
  type definitions from another deployed DMN model identified by
  its `namespace`.
  """

  @type t :: %__MODULE__{
          id: String.t() | nil,
          namespace: String.t(),
          location_uri: String.t() | nil,
          import_type: String.t()
        }

  @enforce_keys [:namespace, :import_type]
  defstruct [:id, :namespace, :location_uri, :import_type]
end
