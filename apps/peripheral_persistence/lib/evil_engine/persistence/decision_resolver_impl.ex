defmodule EvilEngine.Persistence.DecisionResolverImpl do
  @moduledoc """
  Ash-backed implementation of `EvilEngine.Execution.DecisionResolver`.

  Resolves a DMN decision definition ID to its latest enabled, non-deleted
  version by querying the `decision_definitions` and `decision_versions` tables.
  """

  @behaviour EvilEngine.Execution.DecisionResolver

  require Ash.Query

  alias EvilEngine.Persistence.Resources.DecisionDefinition
  alias EvilEngine.Persistence.Resources.DecisionVersion

  @domain EvilEngine.Persistence.Api

  @doc "Resolves the latest enabled, non-deleted version for the given decision definition ID."
  @impl true
  def resolve_latest_version(decision_definition_id) do
    with {:ok, definition} <- find_enabled_definition(decision_definition_id),
         {:ok, version} <- find_latest_version(definition.id) do
      {:ok,
       %{
         decision_definition_id: definition.decision_definition_id,
         decision_version_id: version.id,
         version: version.version,
         dmn_xml: version.dmn_xml
       }}
    end
  end

  defp find_enabled_definition(decision_definition_id) do
    query =
      DecisionDefinition
      |> Ash.Query.filter(decision_definition_id == ^decision_definition_id)
      |> Ash.Query.limit(1)

    case Ash.read(query, domain: @domain, authorize?: false) do
      {:ok, [%{enabled: true} = definition]} -> {:ok, definition}
      {:ok, [%{enabled: false}]} -> {:error, :decision_disabled}
      {:ok, []} -> {:error, :decision_definition_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp find_latest_version(definition_id) do
    query =
      DecisionVersion
      |> Ash.Query.filter(decision_definition_id == ^definition_id)
      |> Ash.Query.sort(deployed_at: :desc)
      |> Ash.Query.limit(1)

    case Ash.read(query, domain: @domain, authorize?: false) do
      {:ok, [version]} -> {:ok, version}
      {:ok, []} -> {:error, :no_version_available}
      {:error, reason} -> {:error, reason}
    end
  end
end
