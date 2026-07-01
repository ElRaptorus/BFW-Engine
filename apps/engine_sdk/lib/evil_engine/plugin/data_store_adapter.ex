defmodule EvilEngine.Plugin.DataStoreAdapter do
  @moduledoc """
  External data store integration for BPMN DataStore references.

  Unique per `store_id`.
  """

  @callback store_id() :: String.t()
  @callback read(key :: String.t(), opts :: keyword()) :: {:ok, term()} | {:error, term()}
  @callback write(key :: String.t(), value :: term(), opts :: keyword()) :: :ok | {:error, term()}
end
