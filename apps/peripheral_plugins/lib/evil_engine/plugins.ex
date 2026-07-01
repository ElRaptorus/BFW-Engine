defmodule EvilEngine.Plugins do
  @moduledoc """
  Public namespace for the engine's plugin host.

  Phase 0 only scaffolds the supervision tree. The registry, the
  in-BEAM loader (`EVIL_PLUGINS_INBEAM`), the sidecar manifest scanner
  (`EVIL_PLUGINS_SIDECAR_DIR`), the conflict detector, the gRPC bridge,
  and the engine-injected facade all land in Phase 9.

  ## Loading model (per `docs/ImplementationPlan.md` §9.2)

  The **engine drives lifecycle**, plugins do not. Both tiers feed the
  same registry and look identical to downstream consumers.

  - **In-BEAM tier (§9.2.2).** Plugins are OTP apps bundled into the
    custom release. Operators name them in `EVIL_PLUGINS_INBEAM`; the
    engine reads `Application.spec(app, :plugin_module)` to find each
    plugin's `@behaviour EvilEngine.Plugin` callback module and calls
    `on_load/1` (then `on_ready/1`) directly. Plugin
    `Application.start/2` callbacks MUST NOT call the registry.
  - **Sidecar tier (§9.2.3).** The engine scans
    `EVIL_PLUGINS_SIDECAR_DIR` (default `~/.evil/engine/plugins`) for
    subdirectories containing `plugin.toml`, launches each binary as a
    supervised `Port`, and drives lifecycle over a bidirectional gRPC
    stream on a per-plugin Unix-domain socket.

  Both tiers honor `EVIL_PLUGINS_INCLUDE` / `EVIL_PLUGINS_EXCLUDE`
  (exclude wins on conflict). Failures during discovery or `on_load`
  quarantine the offending plugin and emit `Event.PluginQuarantined` —
  engine boot continues regardless.
  """
end
