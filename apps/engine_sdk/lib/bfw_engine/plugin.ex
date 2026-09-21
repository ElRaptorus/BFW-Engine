defmodule BfwEngine.Plugin do
  @moduledoc """
  Public namespace for every plugin-author behaviour.

  ## Available behaviours

  | Category | Module | Conflict rule |
  |----------|--------|---------------|
  | Event sink | `BfwEngine.Plugin.EventSink` | Many allowed |
  | Service Task handler | `BfwEngine.Plugin.ServiceTaskHandler` | Unique by `implementation` |
  | REST API extension | `BfwEngine.Plugin.RestApiExtension` | Mounted under prefix |
  | Named script | `BfwEngine.Plugin.NamedScript` | Unique by script-key |
  | Auth provider | `BfwEngine.Plugin.AuthProvider` | Unique (singleton, first-writer wins) |

  ## Umbrella plugin lifecycle

  Plugins implementing `@behaviour BfwEngine.Plugin` receive two
  engine-driven callbacks: `on_load/1` and `on_ready/1`. See the
  `BfwEngine.Plugin` behaviour definition for details.
  """

  @doc """
  Called after core_execution reports steady state, before the API tier
  exposes its sockets. Register handlers, subscribe to events, read
  engine info. Failures quarantine the plugin (§9.3).
  """
  @callback on_load(engine_facade :: struct()) :: :ok | {:error, term()}

  @doc """
  Called after every plugin's `on_load` has returned and the API tier
  has bound its listening sockets. Perform work that requires the engine
  to be reachable end-to-end.
  """
  @callback on_ready(engine_facade :: struct()) :: :ok | {:error, term()}
end
