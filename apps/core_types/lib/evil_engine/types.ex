defmodule EvilEngine.Types do
  @moduledoc """
  Umbrella namespace for every cross-cutting, behaviour-free struct /
  type alias in the Daemon Engine.

  Every type lives in its own module under this namespace; this
  module itself has no code.

  Per-subject modules arrive with their owning feature:

    * `EvilEngine.Types.Identity` — JWT-derived identity claim (§13).
    * `EvilEngine.Types.Token` — process execution token.
    * `EvilEngine.Types.PayloadEnvelope` — `{data, metadata}` wrapper.
    * `EvilEngine.Types.Event.*` — one struct per `:telemetry` event.
    * `EvilEngine.Types.Error` — canonical tagged-error tuples.

  They are added during Phase 1+. Phase 0 only establishes the app.
  """
end
