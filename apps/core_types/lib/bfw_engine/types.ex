defmodule BfwEngine.Types do
  @moduledoc """
  Umbrella namespace for every cross-cutting, behaviour-free struct /
  type alias in the Engine.

  Every type lives in its own module under this namespace; this
  module itself has no code.

  Per-subject modules arrive with their owning feature:

    * `BfwEngine.Types.Identity` — JWT-derived identity claim (§13).
    * `BfwEngine.Types.Token` — process execution token.
    * `BfwEngine.Types.PayloadEnvelope` — `{data, metadata}` wrapper.
    * `BfwEngine.Types.Event.*` — one struct per `:telemetry` event.
    * `BfwEngine.Types.Error` — canonical tagged-error tuples.

  They are added during Phase 1+. Phase 0 only establishes the app.
  """
end
