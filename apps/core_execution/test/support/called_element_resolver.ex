defmodule BfwEngine.Execution.TestSupport.CalledElementResolver do
  @moduledoc false

  @behaviour BfwEngine.Execution.CalledElementResolver

  @default_version_id "test-version-id"
  @default_model_hash "test-hash"

  @impl true
  def resolve_latest_version(process_model_id) do
    case :persistent_term.get({__MODULE__, process_model_id}, nil) do
      nil ->
        {:ok, default_resolved(process_model_id, "1.0.0")}

      version_id ->
        {:ok, default_resolved(process_model_id, "1.0.0", version_id)}
    end
  end

  @impl true
  def resolve_specific_version(process_model_id, version) do
    case :persistent_term.get({__MODULE__, :specific, process_model_id, version}, :unset) do
      :unset ->
        {:ok, default_resolved(process_model_id, version)}

      {:error, reason} ->
        {:error, reason}

      version_id ->
        {:ok, default_resolved(process_model_id, version, version_id)}
    end
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

  def set_version(process_model_id, version_id) do
    :persistent_term.put({__MODULE__, process_model_id}, version_id)
  end

  def set_specific_version(process_model_id, version_string, result) do
    :persistent_term.put({__MODULE__, :specific, process_model_id, version_string}, result)
  end

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

  defp default_resolved(process_model_id, version, version_id \\ @default_version_id) do
    %{
      process_version_id: version_id,
      process_model_id: process_model_id,
      version: version,
      process_model_hash: @default_model_hash
    }
  end
end
