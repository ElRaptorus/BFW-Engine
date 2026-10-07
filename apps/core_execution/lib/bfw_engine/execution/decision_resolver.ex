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
  @moduledoc "Stub resolver that always returns a fixed decision version."

  @behaviour BfwEngine.Execution.DecisionResolver

  @impl true
  def resolve_latest_version(decision_definition_id) do
    {:ok,
     %{
       decision_version_id: "test-dmn-version-id",
       version: "1.0.0",
       decision_definition_id: decision_definition_id
     }}
  end
end
