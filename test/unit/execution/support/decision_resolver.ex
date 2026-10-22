defmodule BfwEngine.Execution.TestSupport.DecisionResolver do
  @moduledoc false

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

  def set_version(decision_definition_id, version_id) do
    :persistent_term.put({__MODULE__, :version, decision_definition_id}, version_id)
  end

  def set_error(decision_definition_id, error_reason) do
    :persistent_term.put({__MODULE__, :error, decision_definition_id}, error_reason)
  end

  def reset do
    :persistent_term.get()
    |> Enum.each(fn
      {{__MODULE__, _kind, _key}, _value} = {key, _} -> :persistent_term.erase(key)
      _ -> :ok
    end)
  end
end
