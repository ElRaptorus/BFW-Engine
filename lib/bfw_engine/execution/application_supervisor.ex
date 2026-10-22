defmodule BfwEngine.Execution.ApplicationSupervisor do
  @moduledoc """
  Supervision tree of the execution runtime.

  Starts the PI Registry and the PI DynamicSupervisor
  (`BfwEngine.Execution.Supervisor`). The one-shot `ResumeRunner` task is NOT
  started here — it lives in `BfwEngine.Persistence.Supervisor`, which starts
  after this tree, so the Ecto Repo is available when the resume query runs.
  """

  use Supervisor

  @spec start_link(term()) :: Supervisor.on_start()
  def start_link(_options), do: Supervisor.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    # Cap enforcement (`BFE_MAX_CONCURRENT_PIS`) lives in
    # `Execution.start_process_instance/1` as a soft client-side pre-check, NOT
    # on the supervisor itself. This lets `ResumeRunner` bypass the cap entirely
    # at boot — every `:running` PI from the DB is brought back online,
    # regardless of `BFE_MAX_CONCURRENT_PIS`. The cap applies only to new starts
    # via the public API. See `docs/architecture/execution.md` Resume on Startup.
    children = [
      {Registry, keys: :unique, name: BfwEngine.Execution.Registry},
      {DynamicSupervisor,
       strategy: :one_for_one, name: BfwEngine.Execution.Supervisor, max_children: :infinity},
      {BfwEngine.Execution.TimerStartListener, []}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
