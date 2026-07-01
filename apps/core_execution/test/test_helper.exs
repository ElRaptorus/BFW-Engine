Application.put_env(:core_execution, :persistence_adapter, EvilEngine.Execution.Persistence.NoOp)

case EvilEngine.Timers.Persistence.NoOp.start_link() do
  {:ok, _pid} -> :ok
  {:error, {:already_started, _pid}} -> :ok
end

ExUnit.start()
