defmodule EvilEngine.Timers.Persistence.NoOp do
  @moduledoc """
  In-memory persistence adapter for Timer Start schedules.

  Uses an Agent to store schedules in a map. Intended for unit tests
  where no database is available.
  """

  @behaviour EvilEngine.Timers.Persistence

  use Agent

  @doc "Starts the NoOp persistence agent."
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    Agent.start_link(fn -> %{} end, name: opts[:name] || __MODULE__)
  end

  @doc "Resets all stored schedules. For test isolation."
  @spec reset_state(GenServer.server()) :: :ok
  def reset_state(server \\ __MODULE__) do
    Agent.update(server, fn _state -> %{} end)
  end

  @impl true
  def create_schedule(attrs) do
    schedule_id = attrs[:id] || generate_id()

    record = %{
      id: schedule_id,
      process_version_id: attrs[:process_version_id],
      process_model_id: attrs[:process_model_id],
      flow_node_id: attrs[:flow_node_id],
      kind: attrs[:kind],
      iso_spec: attrs[:iso_spec],
      enabled: Map.get(attrs, :enabled, true),
      next_fire_at: attrs[:next_fire_at],
      last_triggered_at: attrs[:last_triggered_at],
      cycle_total: attrs[:cycle_total],
      cycle_remaining: attrs[:cycle_remaining],
      scheduler_ref: attrs[:scheduler_ref]
    }

    Agent.update(__MODULE__, fn state -> Map.put(state, schedule_id, record) end)
    {:ok, record}
  end

  @impl true
  def update_schedule(id, changes) do
    Agent.get_and_update(__MODULE__, fn state ->
      case Map.get(state, id) do
        nil ->
          {{:error, :not_found}, state}

        existing ->
          updated = Map.merge(existing, changes)
          {{:ok, updated}, Map.put(state, id, updated)}
      end
    end)
  end

  @impl true
  def delete_schedules_for_version(process_version_id) do
    Agent.update(__MODULE__, fn state ->
      state
      |> Enum.reject(fn {_id, record} -> record.process_version_id == process_version_id end)
      |> Map.new()
    end)

    :ok
  end

  @impl true
  def list_armed_schedules do
    schedules =
      Agent.get(__MODULE__, fn state ->
        state
        |> Map.values()
        |> Enum.filter(fn record -> record.enabled && record.next_fire_at != nil end)
        |> Enum.sort_by(fn record -> record.next_fire_at end, DateTime)
      end)

    {:ok, schedules}
  end

  @impl true
  def list_all_schedules(opts \\ []) do
    schedules =
      Agent.get(__MODULE__, fn state ->
        values = Map.values(state)
        apply_list_filters(values, opts)
      end)

    {:ok, schedules}
  end

  defp apply_list_filters(schedules, opts) do
    Enum.reduce(opts, schedules, fn
      {:process_version_id, version_id}, acc ->
        Enum.filter(acc, &(&1.process_version_id == version_id))

      _other, acc ->
        acc
    end)
  end

  @impl true
  def get_schedule(id) do
    case Agent.get(__MODULE__, fn state -> Map.get(state, id) end) do
      nil -> {:error, :not_found}
      record -> {:ok, record}
    end
  end

  defp generate_id do
    Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
  end
end
