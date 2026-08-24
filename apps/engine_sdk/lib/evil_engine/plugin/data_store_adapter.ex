defmodule EvilEngine.Plugin.DataStoreAdapter do
  @moduledoc """
  External data store integration for BPMN DataStore references.

  **Not implemented in v1.** Registration is accepted and ignored at
  runtime. BPMN DataStores are a parser no-op in this release. Do not
  depend on this behaviour being invoked.

  Unique per `store_id` if this capability is ever wired.
  """

  @callback store_id() :: String.t()
  @callback read(key :: String.t(), opts :: keyword()) :: {:ok, term()} | {:error, term()}
  @callback write(key :: String.t(), value :: term(), opts :: keyword()) :: :ok | {:error, term()}
end
