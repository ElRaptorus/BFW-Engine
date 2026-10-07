defmodule BfwEngine.Auth.ServiceReset do
  @moduledoc false

  def provider_registry do
    restart(BfwEngine.Auth.Supervisor, BfwEngine.Auth.ProviderRegistry)
  end

  defp restart(supervisor, child_id) do
    :ok = Supervisor.terminate_child(supervisor, child_id)

    case Supervisor.restart_child(supervisor, child_id) do
      {:ok, _child} -> :ok
      {:ok, _child, _info} -> :ok
    end
  end
end
