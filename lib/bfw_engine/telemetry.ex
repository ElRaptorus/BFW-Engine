defmodule BfwEngine.Telemetry do
  @moduledoc """
  In-process `:telemetry` counters and the `/stats` snapshot
  (`StatsCollector`). The plugin list in `/stats` is added by
  `BfwEngineWeb.Http.StatsController`, so Telemetry does not depend on the
  plugin host.
  """

  use Boundary,
    deps: [
      BfwEngine.Types,
      BfwEngine.Events,
      BfwEngine.Timers,
      BfwEngine.Persistence,
      BfwEngine.Plugin
    ],
    exports: [StatsCollector]
end
