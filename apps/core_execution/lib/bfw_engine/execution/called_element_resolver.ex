defmodule BfwEngine.Execution.CalledElementResolver do
  @moduledoc """
  Behaviour for resolving a called element reference (process model ID)
  to a deployable process version.

  Used by the Call Activity handler to look up which process version
  to spawn as a child PI.

  The actual implementation lives in `peripheral_persistence` and is
  wired via application config (`:core_execution, :called_element_resolver`).
  In tests, the NoOp adapter returns a configurable stub.
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
  @moduledoc """
  Stub resolver for tests.

  Stores mappings in the process dictionary so tests can configure
  which version ID is returned for a given process model ID:

      CalledElementResolver.NoOp.set_version("child-process", "version-abc")
  """

  @behaviour BfwEngine.Execution.CalledElementResolver

  @default_version_id "test-version-id"
  @default_model_hash "test-hash"

  @doc "Returns a stub version map, using configured overrides or test defaults."
  @impl true
  def resolve_latest_version(process_model_id) do
    case :persistent_term.get({__MODULE__, process_model_id}, nil) do
      nil ->
        {:ok,
         %{
           process_version_id: @default_version_id,
           process_model_id: process_model_id,
           version: "1.0.0",
           process_model_hash: @default_model_hash
         }}

      version_id ->
        {:ok,
         %{
           process_version_id: version_id,
           process_model_id: process_model_id,
           version: "1.0.0",
           process_model_hash: @default_model_hash
         }}
    end
  end

  @doc "Resolves a specific version by model ID and version string (stub)."
  @impl true
  def resolve_specific_version(process_model_id, version) do
    case :persistent_term.get({__MODULE__, :specific, process_model_id, version}, :unset) do
      :unset ->
        {:ok,
         %{
           process_version_id: @default_version_id,
           process_model_id: process_model_id,
           version: version,
           process_model_hash: @default_model_hash
         }}

      {:error, reason} ->
        {:error, reason}

      version_id ->
        {:ok,
         %{
           process_version_id: version_id,
           process_model_id: process_model_id,
           version: version,
           process_model_hash: @default_model_hash
         }}
    end
  end

  @doc "Resolves latest version by internal process UUID (stub)."
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

  @doc "Configure the version ID returned for a given process model ID."
  def set_version(process_model_id, version_id) do
    :persistent_term.put({__MODULE__, process_model_id}, version_id)
  end

  @doc """
  Configure `resolve_specific_version/2` for `{process_model_id, version_string}`.

  `result` is either a process-version id string or `{:error, reason}`.
  """
  def set_specific_version(process_model_id, version_string, result) do
    :persistent_term.put({__MODULE__, :specific, process_model_id, version_string}, result)
  end

  @doc "Clear all configured version mappings."
  def reset do
    :persistent_term.get()
    |> Enum.each(fn
      {{__MODULE__, :specific, _process_model_id, _version_string}, _value} = {key, _} ->
        :persistent_term.erase(key)

      {{__MODULE__, _key}, _value} = {key, _} ->
        :persistent_term.erase(key)

      _ ->
        :ok
    end)
  end
end
