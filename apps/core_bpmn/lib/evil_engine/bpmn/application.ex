defmodule EvilEngine.BPMN.Application do
  @moduledoc false

  use Application

  alias EvilEngine.BPMN.ModelCache
  alias EvilEngine.BPMN.SeedingRunner

  @impl true
  def start(_type, _args) do
    children = [ModelCache]
    opts = [strategy: :one_for_one, name: EvilEngine.BPMN.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        SeedingRunner.run()
        {:ok, pid}

      error ->
        error
    end
  end
end
