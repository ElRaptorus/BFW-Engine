defmodule BfwEngine.Events do
  @moduledoc """
  Public namespace for the engine's event bus.

  The real `EngineEventBus`, the three built-in sinks
  (`console`, `telemetry`, `websocket`), and the
  `PendingSweeper` land in Phase 1 / Phase 2. The built-in
  `database` sink was removed. Phase 0 only
  wires the supervision tree and a thin `Phoenix.PubSub` instance
  (`BfwEngine.PubSub`) used by every other app.
  """

  @pubsub_name BfwEngine.PubSub

  @doc "Name of the shared Phoenix.PubSub server used by the engine."
  @spec pubsub_name() :: BfwEngine.PubSub
  def pubsub_name, do: @pubsub_name
end
