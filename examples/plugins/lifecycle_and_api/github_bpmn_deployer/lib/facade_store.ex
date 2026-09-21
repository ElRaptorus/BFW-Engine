defmodule Examples.Plugins.GithubBpmnDeployer.FacadeStore do
  @moduledoc """
  Agent-backed stash for the `BfwEngine.EngineFacade` received during
  `on_load/1` so the deployer worker can access the wired facade closures.
  """

  use Agent

  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(options \\ []) do
    Agent.start_link(fn -> nil end, Keyword.take(options, [:name]))
  end

  @spec put(BfwEngine.EngineFacade.t()) :: :ok
  def put(engine_facade) do
    ensure_started()
    Agent.update(__MODULE__, fn _previous -> engine_facade end)
  end

  @spec get() :: BfwEngine.EngineFacade.t() | nil
  def get do
    ensure_started()
    Agent.get(__MODULE__, & &1)
  end

  defp ensure_started do
    case Process.whereis(__MODULE__) do
      nil -> start_link(name: __MODULE__)
      _registered -> :ok
    end
  end
end
