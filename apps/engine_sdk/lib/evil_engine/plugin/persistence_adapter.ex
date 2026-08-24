defmodule EvilEngine.Plugin.PersistenceAdapter do
  @moduledoc """
  Plugin-facade persistence adapter.

  **Not implemented in v1.** Registration is accepted and ignored at
  runtime. This is not `EvilEngine.Execution.Persistence` (the in-tree
  execution adapter swapped via `:core_execution, :persistence_adapter`
  config). Do not depend on this behaviour replacing AshPostgres.

  Unique registration if this capability is ever wired.
  """

  @callback init(opts :: keyword()) :: {:ok, state :: term()} | {:error, term()}
  @callback persist(changeset :: term(), state :: term()) :: {:ok, term()} | {:error, term()}
end
