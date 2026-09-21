defmodule BfwEngine.SDK do
  @moduledoc """
  Convenience entry-point for plugin authors.

  ## Event publishing

  Plugins receive an `%BfwEngine.EngineFacade{}` in their `on_load/1`
  and `on_ready/1` callbacks. Use the facade's closures rather than
  reaching into internal GenServers:

      def on_load(facade) do
        facade.publish_event.(%BfwEngine.Types.Event.EngineStarted{
          engine_id: facade.engine_id,
          occurred_at: DateTime.utc_now()
        })

        facade.register_service_task_handler.("evil:my_task", MyPlugin.MyHandler)

        :ok
      end

  ## Re-exported types

  All `BfwEngine.Types.*` structs are available via `core_types`,
  which is a transitive dependency of `engine_sdk`.

  ## Available behaviours

  See `BfwEngine.Plugin` for the full table of behaviours a plugin
  can implement. Each behaviour module lives under
  `BfwEngine.Plugin.*` (e.g. `BfwEngine.Plugin.EventSink`).
  """
end
