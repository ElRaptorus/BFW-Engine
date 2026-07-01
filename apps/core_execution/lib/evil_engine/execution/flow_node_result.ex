defmodule EvilEngine.Execution.FlowNodeResult do
  @moduledoc """
  Canonical return struct from `FlowNodeHandler.handle_enter/3`.

  - `output_payload` — data carried forward as the next token's payload.
    `nil` means "pass through the input token payload unchanged."
  - `next_flow_node_ids` — list of flow node IDs that the PI should
    dispatch next. Every handler is responsible for determining its own
    routing: non-gateway handlers delegate to `SequenceFlowResolver`,
    gateway handlers implement element-specific routing logic.
  - `type_properties` — per-element runtime state snapshot, written to
    `flow_node_instances.type_properties` (e.g. form schema for User
    Tasks, End Event ID for FinalToken decoration).
  - `metadata` — transient info not persisted (e.g. handler timing).
  """

  @type t :: %__MODULE__{
          output_payload: term(),
          next_flow_node_ids: [String.t()],
          type_properties: map(),
          metadata: map()
        }

  @enforce_keys []
  defstruct output_payload: nil, next_flow_node_ids: [], type_properties: %{}, metadata: %{}
end
