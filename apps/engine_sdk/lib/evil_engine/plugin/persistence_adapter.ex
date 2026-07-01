defmodule EvilEngine.Plugin.PersistenceAdapter do
  @moduledoc """
  Replaces or chains the default AshPostgres persistence layer.

  Unique registration; chained if `chain: true`, else last-wins.
  """

  @callback init(opts :: keyword()) :: {:ok, state :: term()} | {:error, term()}
  @callback persist(changeset :: term(), state :: term()) :: {:ok, term()} | {:error, term()}
end
