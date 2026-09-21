defmodule BfwEngine.Execution.DecisionResolver do
  @moduledoc """
  Behaviour for resolving a decision definition ID to its latest
  enabled, non-deleted version.

  Follows the same pattern as `CalledElementResolver`.
  """

  @callback resolve_latest_version(decision_definition_id :: String.t()) ::
              {:ok, resolved :: map()} | {:error, reason :: term()}

  @doc "Returns the configured decision resolver module."
  @spec adapter() :: module()
  def adapter do
    Application.get_env(:core_execution, :decision_resolver, __MODULE__.NoOp)
  end
end

defmodule BfwEngine.Execution.DecisionResolver.NoOp do
  @moduledoc """
  Stub resolver for tests.

  Stores mappings in persistent_term so tests can configure
  which version ID is returned for a given decision definition ID.
  """

  @behaviour BfwEngine.Execution.DecisionResolver

  @impl true
  def resolve_latest_version(decision_definition_id) do
    case :persistent_term.get({__MODULE__, :error, decision_definition_id}, nil) do
      nil ->
        version_id =
          :persistent_term.get(
            {__MODULE__, :version, decision_definition_id},
            "test-dmn-version-id"
          )

        {:ok,
         %{
           decision_version_id: version_id,
           version: "1.0.0",
           decision_definition_id: decision_definition_id
         }}

      error_reason ->
        {:error, error_reason}
    end
  end

  @doc "Configure the version ID returned for a given decision definition ID."
  def set_version(decision_definition_id, version_id) do
    :persistent_term.put({__MODULE__, :version, decision_definition_id}, version_id)
  end

  @doc "Configure an error returned for a given decision definition ID."
  def set_error(decision_definition_id, error_reason) do
    :persistent_term.put({__MODULE__, :error, decision_definition_id}, error_reason)
  end

  @doc "Clear all configured version mappings and error overrides."
  def reset do
    :persistent_term.get()
    |> Enum.each(fn
      {{__MODULE__, _kind, _key}, _val} = {key, _} -> :persistent_term.erase(key)
      _ -> :ok
    end)
  end
end
