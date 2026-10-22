defmodule BfwEngine.Types.FinalToken do
  @moduledoc """
  Decorated End Event result.

  One struct per End Event FNI that reached `finished`. The PI's
  result is expressed as a `[FinalToken]` array — consumers can
  reconstruct which End Event produced which result.

  Also used by Call Activity result aggregation: the parent handler
  collects all child End Events into the same shape.
  """

  @type t :: %__MODULE__{
          end_event_id: String.t(),
          end_event_name: String.t() | nil,
          payload: term()
        }

  @enforce_keys [:end_event_id]
  defstruct [
    :end_event_id,
    :end_event_name,
    :payload
  ]
end
