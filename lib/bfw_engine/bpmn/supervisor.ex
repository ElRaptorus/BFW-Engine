defmodule BfwEngine.BPMN.Supervisor do
  @moduledoc false

  use Supervisor

  alias BfwEngine.BPMN.ModelCache
  alias BfwEngine.BPMN.SeedingRunner

  @spec start_link(term()) :: Supervisor.on_start()
  def start_link(_options) do
    case Supervisor.start_link(__MODULE__, :ok, name: __MODULE__) do
      {:ok, pid} ->
        SeedingRunner.run()
        {:ok, pid}

      error ->
        error
    end
  end

  @impl true
  def init(:ok), do: Supervisor.init([ModelCache], strategy: :one_for_one)
end
