Application.put_env(:core_execution, :persistence_adapter, BfwEngine.Execution.Persistence.NoOp)

case BfwEngine.Timers.Persistence.NoOp.start_link() do
  {:ok, _pid} -> :ok
  {:error, {:already_started, _pid}} -> :ok
end

ExUnit.start()
