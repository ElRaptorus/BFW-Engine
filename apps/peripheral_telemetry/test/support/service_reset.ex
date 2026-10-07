defmodule BfwEngine.Telemetry.ServiceReset do
  @moduledoc false

  def engine_event_bus do
    stop_sink_workers()
    restart(BfwEngine.Events.Supervisor, BfwEngine.Events.EngineEventBus)
  end

  defp stop_sink_workers do
    supervisor = BfwEngine.Events.SinkSupervisor

    supervisor
    |> DynamicSupervisor.which_children()
    |> Enum.each(fn
      {_id, pid, _type, _modules} when is_pid(pid) ->
        DynamicSupervisor.terminate_child(supervisor, pid)

      _other ->
        :ok
    end)
  end

  defp restart(supervisor, child_id) do
    :ok = Supervisor.terminate_child(supervisor, child_id)

    case Supervisor.restart_child(supervisor, child_id) do
      {:ok, _child} -> :ok
      {:ok, _child, _info} -> :ok
    end
  end
end
