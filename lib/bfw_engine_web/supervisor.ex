defmodule BfwEngineWeb.Supervisor do
  @moduledoc false

  use Supervisor

  @spec start_link(term()) :: Supervisor.on_start()
  def start_link(_options), do: Supervisor.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok), do: Supervisor.init([BfwEngineWeb.Http.Endpoint], strategy: :one_for_one)
end
