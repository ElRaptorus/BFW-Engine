defmodule BfwEngine.BPMN.ServiceReset do
  @moduledoc false

  def bpmn_model_cache do
    restart(BfwEngine.BPMN.Supervisor, BfwEngine.BPMN.ModelCache)
  end

  defp restart(supervisor, child_id) do
    :ok = Supervisor.terminate_child(supervisor, child_id)

    case Supervisor.restart_child(supervisor, child_id) do
      {:ok, _child} -> :ok
      {:ok, _child, _info} -> :ok
    end
  end
end
