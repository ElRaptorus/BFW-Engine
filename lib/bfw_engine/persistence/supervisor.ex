defmodule BfwEngine.Persistence.Supervisor do
  @moduledoc """
  Supervision tree of the persistence layer.

  Starts the Ecto Repo first, then triggers the one-shot boot task: warm
  the start-event index, then run `ResumeRunner`. The task lives here
  (rather than in `BfwEngine.Execution`) to guarantee the Repo is available
  when its queries run. The resume *logic* remains in `BfwEngine.Execution`
  (dependency direction: Peripheral -> Core).
  """

  use Supervisor

  require Logger

  alias BfwEngine.BPMN.ModelCache
  alias BfwEngine.Execution.ResumeRunner
  alias BfwEngine.Persistence.Resources.ProcessVersion
  alias BfwEngine.Timers.StartEventManager

  @spec start_link(term()) :: Supervisor.on_start()
  def start_link(_options), do: Supervisor.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    children = [
      BfwEngine.Persistence.Repo,
      BfwEngine.Persistence.ReadRepo,
      Supervisor.child_spec({Task, &warm_and_resume/0}, id: :resume_runner_task),
      Supervisor.child_spec(
        {Task, &safe_reload_timer_schedules/0},
        id: :reload_timer_schedules_task
      )
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Load the latest live version of every process (enabled or not) into
  `ModelCache`, which indexes its message and signal start events.

  Message and signal starts discover candidates through that index, and
  `ResumeRunner` marks the subscriptions ready only after this ran, so a
  publish after boot sees every deployed start event.
  """
  @spec warm_start_event_index() :: :ok
  def warm_start_event_index do
    ProcessVersion
    |> Ash.Query.select([:id, :process_id, :deployed_at])
    |> Ash.Query.sort(deployed_at: :desc)
    |> Ash.read!(authorize?: false)
    |> Enum.uniq_by(& &1.process_id)
    |> Enum.each(fn version ->
      case ModelCache.fetch(version.id) do
        {:ok, _definitions} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "Start-event index: process version #{version.id} could not be loaded: " <>
              inspect(reason)
          )
      end
    end)
  end

  defp warm_and_resume do
    safe_boot_step("warm_start_event_index", &warm_start_event_index/0)
    ResumeRunner.resume_all()
  end

  defp safe_reload_timer_schedules do
    safe_boot_step("StartEventManager.reload_start_schedules", fn ->
      case StartEventManager.reload_start_schedules() do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "StartEventManager.reload_start_schedules failed at boot: #{inspect(reason)}"
          )
      end
    end)
  end

  defp safe_boot_step(name, step) do
    step.()
  rescue
    error -> Logger.warning("#{name} failed at boot: #{inspect(error)}")
  catch
    :exit, reason -> Logger.warning("#{name} exited at boot: #{inspect(reason)}")
  end
end
