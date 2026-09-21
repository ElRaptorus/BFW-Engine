defmodule Examples.Plugins.CustomValidators.Scripts.IdempotencyGuard do
  @moduledoc """
  Blocks execution when a boolean flag lives in `data_objects` under `"processed_flag"`.
  """

  @behaviour BfwEngine.Plugin.NamedScript

  @doc "For a map payload, blocks when data_objects marks processed_flag true and otherwise records processing_started; rejects non-map payloads with an error."
  @impl true
  def handle_enter(_flow_node, payload, context) when is_map(payload) do
    data_objects =
      if is_map(context) do
        Map.get(context, :data_objects, %{})
      else
        %{}
      end

    case Map.get(data_objects, "processed_flag") do
      true -> {:error, "already processed"}
      _ -> {:ok, Map.put(payload, "processing_started", true)}
    end
  end

  def handle_enter(_flow_node, _payload, _context) do
    {:error, "payload must be a map"}
  end
end
