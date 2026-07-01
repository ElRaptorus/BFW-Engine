defmodule EvilEngine.Events do
  @moduledoc """
  Public namespace for the engine's event bus.

  The real `EngineEventBus`, the four built-in sinks, and the
  `PendingSweeper` land in Phase 1 / Phase 2. Phase 0 only
  wires the supervision tree and a thin `Phoenix.PubSub` instance
  (`EvilEngine.PubSub`) used by every other app.
  """

  @pubsub_name EvilEngine.PubSub

  @doc "Name of the shared Phoenix.PubSub server used by the engine."
  @spec pubsub_name() :: EvilEngine.PubSub
  def pubsub_name, do: @pubsub_name
end
