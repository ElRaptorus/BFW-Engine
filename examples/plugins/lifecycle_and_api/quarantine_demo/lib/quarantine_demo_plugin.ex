defmodule Examples.Plugins.QuarantineDemo.QuarantineDemoPlugin do
  @moduledoc """
  Demonstrates Loader quarantine: `on_load/1` returns `{:error, :intentional_quarantine}`
  and registers **nothing** first.

  This matches `EvilEngine.Plugins.Loader` `run_on_load`: `{:error, reason}` →
  `quarantine/2` → `Event.PluginQuarantined` (`tier: :inbeam`,
  `reason: {:on_load_failed, :intentional_quarantine}`). Engine boot continues.
  Quarantined plugins do not auto-revive.

  Do **not** register a handler and then fail `on_load`: Loader does **not**
  call `Registry.unregister_plugin_capabilities/1` on `on_load` failure (only
  `on_ready` failure rolls back). Teach the real contract.
  """

  @behaviour EvilEngine.Plugin

  @doc "Returns an error without registering capabilities so the Loader quarantines this plugin."
  @impl true
  def on_load(_facade) do
    {:error, :intentional_quarantine}
  end

  @doc "Never reached when on_load returns an error."
  @impl true
  def on_ready(_facade), do: :ok
end
