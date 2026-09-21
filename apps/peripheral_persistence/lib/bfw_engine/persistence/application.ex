defmodule BfwEngine.Persistence.Application do
  @moduledoc """
  OTP application for the persistence layer.

  Starts the Ecto Repo first, then triggers the one-shot
  `ResumeRunner` task. The resume task lives here (rather than in
  `core_execution`) to guarantee the Repo is available when the
  resume query runs. The resume *logic* remains in `core_execution`
  (dependency direction: Peripheral -> Core).
  """

  use Application

  alias BfwEngine.Execution.ResumeRunner
  alias BfwEngine.Timers.StartEventManager

  @impl true
  def start(_type, _args) do
    children = [
      BfwEngine.Persistence.Repo,
      BfwEngine.Persistence.ReadRepo,
      Supervisor.child_spec({Task, &ResumeRunner.resume_all/0}, id: :resume_runner_task),
      Supervisor.child_spec(
        {Task, &safe_reload_timer_schedules/0},
        id: :reload_timer_schedules_task
      )
    ]

    opts = [strategy: :one_for_one, name: BfwEngine.Persistence.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp safe_reload_timer_schedules do
    StartEventManager.reload_start_schedules()
  rescue
    error ->
      require Logger

      Logger.warning("StartEventManager.reload_start_schedules failed at boot: #{inspect(error)}")
  catch
    :exit, reason ->
      require Logger

      Logger.warning(
        "StartEventManager.reload_start_schedules exited at boot: #{inspect(reason)}"
      )
  end
end
