defmodule EvilEngine.Execution.TimerStartListener do
  @moduledoc """
  Long-lived GenServer that receives Timer Start fire messages from the
  Scheduler and creates new process instances.

  Registered under `__MODULE__` so the Scheduler can resolve the atom
  target at fire time via `Process.whereis/1`.

  ## Fire handling

  On `{:timer_fired, timer_ref, metadata}`:

  1. Reads `schedule_id` and `process_version_id` from metadata
  2. Verifies the schedule is still enabled (race guard)
  3. Verifies the process version is still cached and active
  4. Creates a new PI via `Execution.start_process_instance/1`
  5. Notifies `StartEventManager.record_fire/1` to update persistence
  6. Emits `Event.TimerFired` on the EngineEventBus
  """

  use GenServer

  require Logger

  alias EvilEngine.BPMN.ModelCache
  alias EvilEngine.Events.EngineEventBus
  alias EvilEngine.Execution
  alias EvilEngine.Timers.StartEventManager
  alias EvilEngine.Types.Event
  alias EvilEngine.Types.Identity

  @system_identity %Identity{
    id: "system:timer-start",
    roles: ["system"],
    groups: ["system"],
    claims: %{"timer_start" => true}
  }

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Logger.info("TimerStartListener started")
    {:ok, %{}}
  end

  @impl true
  def handle_info({:timer_fired, timer_ref, metadata}, state) do
    handle_timer_start_fire(timer_ref, metadata)
    {:noreply, state}
  end

  def handle_info(_message, state) do
    {:noreply, state}
  end

  defp handle_timer_start_fire(timer_ref, metadata) do
    schedule_id = metadata[:schedule_id]
    process_version_id = metadata[:process_version_id]
    flow_node_id = metadata[:flow_node_id]

    with :ok <- verify_schedule_enabled(schedule_id),
         :ok <- verify_version_cached(process_version_id),
         {:ok, _pid} <- start_process_instance(process_version_id, flow_node_id) do
      record_fire_and_emit(schedule_id, timer_ref, flow_node_id)
    else
      {:error, reason} ->
        Logger.warning(
          "TimerStartListener: skipping fire for schedule #{schedule_id}: #{inspect(reason)}"
        )

      {:error, :engine_at_capacity, info} ->
        Logger.warning(
          "TimerStartListener: engine at capacity (#{info.active}/#{info.limit}), " <>
            "skipping timer start for schedule #{schedule_id}"
        )
    end
  end

  defp verify_schedule_enabled(schedule_id) do
    case StartEventManager.get_schedule(schedule_id) do
      {:ok, %{enabled: true}} -> :ok
      {:ok, %{enabled: false}} -> {:error, :schedule_disabled}
      {:error, :not_found} -> {:error, :schedule_not_found}
    end
  end

  defp verify_version_cached(process_version_id) do
    case ModelCache.fetch(process_version_id) do
      {:ok, _definitions} -> :ok
      {:error, _reason} -> {:error, :version_not_cached}
    end
  end

  defp start_process_instance(process_version_id, flow_node_id) do
    process_instance_id = generate_process_instance_id()

    opts = %{
      process_instance_id: process_instance_id,
      process_version_id: process_version_id,
      start_event_id: flow_node_id,
      payload: %{},
      identity: @system_identity
    }

    Execution.start_process_instance(opts)
  end

  defp generate_process_instance_id do
    timestamp_ms = System.system_time(:millisecond)
    <<rand_a::12, rand_b::62, _::6>> = :crypto.strong_rand_bytes(10)

    <<timestamp_ms::48, 7::4, rand_a::12, 2::2, rand_b::62>>
    |> Base.encode16(case: :lower)
    |> then(fn <<a::binary-8, b::binary-4, c::binary-4, d::binary-4, e::binary-12>> ->
      "#{a}-#{b}-#{c}-#{d}-#{e}"
    end)
  end

  defp record_fire_and_emit(schedule_id, timer_ref, flow_node_id) do
    _record_result = StartEventManager.record_fire(schedule_id)

    EngineEventBus.publish(%Event.TimerFired{
      timer_ref: timer_ref,
      process_instance_id: nil,
      flow_node_instance_id: nil,
      flow_node_id: flow_node_id,
      kind: :start,
      occurred_at: DateTime.utc_now()
    })
  end
end
