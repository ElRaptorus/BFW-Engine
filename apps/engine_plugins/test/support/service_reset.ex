defmodule BfwEngine.Plugins.ServiceReset do
  @moduledoc false

  def plugin_registry do
    restart(BfwEngine.Plugins.Supervisor, BfwEngine.Plugins.Registry)
  end

  def loader do
    restart(BfwEngine.Plugins.Supervisor, BfwEngine.Plugins.Loader)
  end

  defp restart(supervisor, child_id) do
    :ok = Supervisor.terminate_child(supervisor, child_id)

    case Supervisor.restart_child(supervisor, child_id) do
      {:ok, _child} -> :ok
      {:ok, _child, _info} -> :ok
    end
  end
end
