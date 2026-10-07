defmodule BfwEngine.Timers.ServiceReset do
  @moduledoc false

  def scheduler do
    restart(BfwEngine.Timers.Supervisor, BfwEngine.Timers.Scheduler)
  end

  def timer_persistence do
    restart(BfwEngine.Timers.Supervisor, BfwEngine.Timers.Persistence.NoOp)
  end

  defp restart(supervisor, child_id) do
    :ok = Supervisor.terminate_child(supervisor, child_id)

    case Supervisor.restart_child(supervisor, child_id) do
      {:ok, _child} -> :ok
      {:ok, _child, _info} -> :ok
    end
  end
end
