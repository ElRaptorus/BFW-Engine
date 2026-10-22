defmodule BfwEngine.Execution.DataObjectWriteIntent do
  @moduledoc """
  Evaluated-but-not-yet-persisted payload for a single DOA write.

  Built by `DataObjectWriter.prepare_associations/4` during the pure
  evaluation phase. The list of intents is then handed to
  `Persistence.finish_fni_with_data_objects/3`, which persists all
  writes together with the FNI state transition in one transaction.

  `previous_value` is retained for event emission (the
  `DataObjectWritten` event carries the previous value so real-time
  consumers can compute deltas). Only the persistence layer drops
  `previous_value` from storage.
  """

  @type t :: %__MODULE__{
          data_object_id: String.t(),
          flow_node_instance_id: String.t(),
          process_instance_id: String.t(),
          previous_value: term(),
          value: term()
        }

  @enforce_keys [:data_object_id, :flow_node_instance_id, :process_instance_id, :value]
  defstruct [
    :data_object_id,
    :flow_node_instance_id,
    :process_instance_id,
    :previous_value,
    :value
  ]
end
