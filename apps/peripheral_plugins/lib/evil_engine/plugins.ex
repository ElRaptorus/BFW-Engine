defmodule EvilEngine.Plugins do
  @moduledoc """
  Public namespace for the engine's plugin host.

  v1 loads **in-BEAM OTP-app plugins only**. There is no
  sidecar scanner, no plugin gRPC protocol, and no process host.
  `TDE_PLUGINS_SIDECAR_DIR` is parsed in `runtime.exs` as a reserved
  no-op.

  ## Loading model (see `docs/architecture/plugins.md`)

  The **engine drives lifecycle**, plugins do not. In-BEAM plugins feed
  the registry; downstream consumers query it by capability.

  - **In-BEAM tier (v1).** Plugins are OTP apps bundled into the
    custom release. Operators name them in `TDE_PLUGINS_INBEAM`; the
    engine reads `Application.spec(app, :plugin_module)` to find each
    plugin's `@behaviour EvilEngine.Plugin` callback module and calls
    `on_load/1` (then `on_ready/1`) directly. Plugin
    `Application.start/2` callbacks MUST NOT call the registry.
  - **Sidecar tier.** **Not shipped.** Design retained in
    `docs/architecture/plugins.md`; not implemented.

  `TDE_PLUGINS_INCLUDE` / `TDE_PLUGINS_EXCLUDE` apply to in-BEAM
  plugins (exclude wins on conflict). Failures during discovery or
  `on_load` quarantine the offending plugin and emit
  `Event.PluginQuarantined` — engine boot continues regardless.
  """
end
