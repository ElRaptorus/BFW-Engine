defmodule BfwEngine.Execution.CalledElementResolver do
  @moduledoc """
  Behaviour for resolving a called element reference (process model ID)
  to a deployable process version.

  Used by the Call Activity handler to look up which process version
  to spawn as a child PI.

  The actual implementation lives in `peripheral_persistence` and is
  wired via application config (`:core_execution, :called_element_resolver`).
  The NoOp adapter returns a fixed stub.
  """

  @callback resolve_latest_version(process_model_id :: String.t()) ::
              {:ok, resolved :: map()} | {:error, reason :: term()}

  @doc """
  Resolve a specific version by process model ID and version string.

  Used by retry/restart when the user specifies a target version.
  Returns `{:error, :version_not_found}` if the version does not exist
  or is soft-deleted, `{:error, :version_disabled}` if the parent
  process is disabled.
  """
  @callback resolve_specific_version(process_model_id :: String.t(), version :: String.t()) ::
              {:ok, resolved :: map()} | {:error, :version_not_found | :version_disabled}

  @doc """
  Resolve the latest version by internal process UUID (not model ID string).

  Used by retry/restart when the user specifies `version: "latest"` and
  we already have the PI's `process_version_id` to derive the process UUID.
  """
  @callback resolve_latest_version_for_process_id(process_id :: String.t()) ::
              {:ok, resolved :: map()} | {:error, reason :: term()}

  @doc "Returns the configured called-element resolver module."
  @spec adapter() :: module()
  def adapter do
    Application.get_env(:core_execution, :called_element_resolver, __MODULE__.NoOp)
  end
end

defmodule BfwEngine.Execution.CalledElementResolver.NoOp do
  @moduledoc "Stub resolver that always returns a fixed version."

  @behaviour BfwEngine.Execution.CalledElementResolver

  @default_version_id "test-version-id"
  @default_model_hash "test-hash"

  @impl true
  def resolve_latest_version(process_model_id) do
    {:ok, resolved(process_model_id, "1.0.0")}
  end

  @impl true
  def resolve_specific_version(process_model_id, version) do
    {:ok, resolved(process_model_id, version)}
  end

  @impl true
  def resolve_latest_version_for_process_id(process_id) do
    {:ok,
     %{
       process_version_id: @default_version_id,
       process_model_id: "stub-model-id",
       process_id: process_id,
       version: "1.0.0",
       process_model_hash: @default_model_hash
     }}
  end

  defp resolved(process_model_id, version) do
    %{
      process_version_id: @default_version_id,
      process_model_id: process_model_id,
      version: version,
      process_model_hash: @default_model_hash
    }
  end
end
