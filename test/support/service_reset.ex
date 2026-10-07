defmodule BfwEngine.Test.ServiceReset do
  @moduledoc false

  def engine_event_bus do
    stop_sink_workers()
    restart(BfwEngine.Events.Supervisor, BfwEngine.Events.EngineEventBus)
  end

  def message_subscriptions do
    restart(BfwEngine.Events.Supervisor, BfwEngine.Events.MessageSubscriptions)
  end

  def signal_subscriptions do
    restart(BfwEngine.Events.Supervisor, BfwEngine.Events.SignalSubscriptions)
  end

  def bpmn_model_cache do
    restart(BfwEngine.BPMN.Supervisor, BfwEngine.BPMN.ModelCache)
  end

  def dmn_model_cache do
    restart(BfwEngine.DMN.Supervisor, BfwEngine.DMN.ModelCache)
  end

  def scheduler do
    restart(BfwEngine.Timers.Supervisor, BfwEngine.Timers.Scheduler)
  end

  def timer_persistence do
    restart(BfwEngine.Timers.Supervisor, BfwEngine.Timers.Persistence.NoOp)
  end

  def plugin_registry do
    restart(BfwEngine.Plugins.Supervisor, BfwEngine.Plugins.Registry)
  end

  def provider_registry do
    restart(BfwEngine.Auth.Supervisor, BfwEngine.Auth.ProviderRegistry)
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
