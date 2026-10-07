defmodule BfwEngine.DMN.ServiceReset do
  @moduledoc false

  def dmn_model_cache do
    restart(BfwEngine.DMN.Supervisor, BfwEngine.DMN.ModelCache)
  end

  defp restart(supervisor, child_id) do
    :ok = Supervisor.terminate_child(supervisor, child_id)

    case Supervisor.restart_child(supervisor, child_id) do
      {:ok, _child} -> :ok
      {:ok, _child, _info} -> :ok
    end
  end
end
