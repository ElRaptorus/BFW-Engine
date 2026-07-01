defmodule Examples.Plugins.Combined.RabbitmqToEngine.OrchestratorCustomEvent do
  @moduledoc """
  Application-defined event struct published through `facade.publish_event/1` so
  co-registered event sinks can observe orchestration decisions alongside engine
  events.
  """

  @enforce_keys [:type, :process_model_id, :timestamp]
  defstruct [
    :type,
    :process_model_id,
    :process_instance_id,
    :payload,
    :timestamp
  ]
end
