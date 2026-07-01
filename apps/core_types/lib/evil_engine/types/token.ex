defmodule EvilEngine.Types.Token do
  @moduledoc """
  A logical marker that moves through a BPMN process graph.

  Carries an immutable ID, the owning process instance, the mutable
  payload (capped by `EVIL_TOKEN_MAX_BYTES`), and a back-pointer
  to the FNI that produced it.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          process_instance_id: String.t(),
          payload: term(),
          originating_flow_node_instance_id: String.t() | nil,
          created_at: DateTime.t()
        }

  @enforce_keys [:id, :process_instance_id]
  defstruct [
    :id,
    :process_instance_id,
    :payload,
    :originating_flow_node_instance_id,
    :created_at
  ]
end
