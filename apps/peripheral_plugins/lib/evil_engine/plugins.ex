defmodule EvilEngine.Plugins do
  @moduledoc """
  Public namespace for the engine's plugin host.

  Plugins are **in-BEAM OTP apps** bundled into the release. The engine
  drives lifecycle; plugins do not. Operators name apps in
  `TDE_PLUGINS_INBEAM`; the engine reads `:plugin_module` from
  application env, then calls `on_load/1` and `on_ready/1`. Plugin
  `Application.start/2` callbacks MUST NOT call the registry.

  `TDE_PLUGINS_INCLUDE` / `TDE_PLUGINS_EXCLUDE` apply (exclude wins on
  conflict). Failures during discovery or `on_load` quarantine the
  offending plugin and emit `Event.PluginQuarantined` — engine boot
  continues regardless.

  See `docs/architecture/plugins.md`.
  """
end
