defmodule BfwEngine.Plugins.Supervisor do
  @moduledoc false

  use Supervisor

  @spec start_link(term()) :: Supervisor.on_start()
  def start_link(_options), do: Supervisor.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    children = [
      BfwEngine.Plugins.Registry,
      BfwEngine.Plugins.Loader
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
