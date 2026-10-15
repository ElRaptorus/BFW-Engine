defmodule BfwEngineWeb.Application do
  @moduledoc false

  use Application

  alias BfwEngineWeb.Http.Endpoint

  @impl true
  def start(_type, _args) do
    children = [
      Endpoint
    ]

    opts = [strategy: :one_for_one, name: BfwEngineWeb.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Applications stop in reverse start order, so this runs before the endpoint,
  # the persistence repo, and core_execution itself go down.
  @impl true
  def prep_stop(state) do
    BfwEngine.Execution.shutdown_process_instances()
    state
  end

  @impl true
  def config_change(changed, _new, removed) do
    Endpoint.config_change(changed, removed)
    :ok
  end
end
