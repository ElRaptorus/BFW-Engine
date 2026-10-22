defmodule BfwEngineWeb do
  @moduledoc """
  API layer: REST, GraphQL, WebSocket, and the admin surface.

  Nothing depends on this namespace.
  """

  use Boundary,
    deps: [
      BfwEngine.Types,
      BfwEngine.Expressions,
      BfwEngine.Timers,
      BfwEngine.Events,
      BfwEngine.BPMN,
      BfwEngine.DMN,
      BfwEngine.Execution,
      BfwEngine.Plugin,
      BfwEngine.EngineFacade,
      BfwEngine.Persistence,
      BfwEngine.Api,
      BfwEngine.Plugins,
      BfwEngine.Telemetry,
      BfwEngine.Auth
    ],
    exports: []
end
