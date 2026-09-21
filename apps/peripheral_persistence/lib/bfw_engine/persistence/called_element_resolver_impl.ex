defmodule BfwEngine.Persistence.CalledElementResolverImpl do
  @moduledoc """
  Ash-backed implementation of `BfwEngine.Execution.CalledElementResolver`.

  Resolves a BPMN process model ID to its latest enabled, non-deleted version
  by querying the `processes` and `process_versions` tables.
  """

  @behaviour BfwEngine.Execution.CalledElementResolver

  require Ash.Query

  alias BfwEngine.Persistence.Resources.Process, as: ProcessResource
  alias BfwEngine.Persistence.Resources.ProcessVersion

  @domain BfwEngine.Persistence.Api

  @doc "Resolves the latest enabled, non-deleted version for the given process model ID."
  @impl true
  def resolve_latest_version(process_model_id) do
    with {:ok, process} <- find_enabled_process(process_model_id),
         {:ok, version} <- find_latest_version(process.id) do
      {:ok, build_resolved_version(process, version)}
    end
  end

  @doc "Resolves a specific version by process model ID and version string."
  @impl true
  def resolve_specific_version(process_model_id, version_string) do
    with {:ok, process} <- find_process_for_version_resolution(process_model_id),
         {:ok, version} <- find_version_by_string(process.id, version_string) do
      {:ok, build_resolved_version(process, version)}
    end
  end

  @doc "Resolves the latest version by internal process UUID."
  @impl true
  def resolve_latest_version_for_process_id(process_id) do
    with {:ok, process} <- find_enabled_process_by_id(process_id),
         {:ok, version} <- find_latest_version(process.id) do
      {:ok, build_resolved_version(process, version)}
    end
  end

  defp build_resolved_version(process, version) do
    %{
      process_id: process.id,
      process_model_id: process.process_model_id,
      process_version_id: version.id,
      version: version.version,
      bpmn_xml: version.bpmn_xml
    }
  end

  defp find_enabled_process(process_model_id) do
    query =
      ProcessResource
      |> Ash.Query.filter(process_model_id == ^process_model_id and enabled == true)
      |> Ash.Query.limit(1)

    case Ash.read(query, domain: @domain, authorize?: false) do
      {:ok, [process]} -> {:ok, process}
      {:ok, []} -> {:error, :process_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp find_enabled_process_by_id(process_id) do
    case Ash.get(ProcessResource, process_id, domain: @domain, authorize?: false) do
      {:ok, %{enabled: true} = process} -> {:ok, process}
      {:ok, %{enabled: false}} -> {:error, :version_disabled}
      {:error, _} -> {:error, :process_not_found}
    end
  end

  defp find_process_for_version_resolution(process_model_id) do
    query =
      ProcessResource
      |> Ash.Query.filter(process_model_id == ^process_model_id)
      |> Ash.Query.limit(1)

    case Ash.read(query, domain: @domain, authorize?: false) do
      {:ok, [%{enabled: true} = process]} -> {:ok, process}
      {:ok, [%{enabled: false}]} -> {:error, :version_disabled}
      {:ok, []} -> {:error, :version_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp find_latest_version(process_id) do
    query =
      ProcessVersion
      |> Ash.Query.filter(process_id == ^process_id)
      |> Ash.Query.sort(deployed_at: :desc)
      |> Ash.Query.limit(1)

    case Ash.read(query, domain: @domain, authorize?: false) do
      {:ok, [version]} -> {:ok, version}
      {:ok, []} -> {:error, :no_version_available}
      {:error, reason} -> {:error, reason}
    end
  end

  defp find_version_by_string(process_id, version_string) do
    query =
      ProcessVersion
      |> Ash.Query.filter(process_id == ^process_id and version == ^version_string)
      |> Ash.Query.limit(1)

    case Ash.read(query, domain: @domain, authorize?: false) do
      {:ok, [version]} -> {:ok, version}
      {:ok, []} -> {:error, :version_not_found}
      {:error, reason} -> {:error, reason}
    end
  end
end
