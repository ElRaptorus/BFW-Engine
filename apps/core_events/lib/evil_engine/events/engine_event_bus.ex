defmodule EvilEngine.Events.EngineEventBus do
  @moduledoc """
  Single typed fan-out surface for every `EvilEngine.Types.Event.*`.

  The bus itself is a thin fan-out registry: it tracks which sinks are
  registered (by name → module) and casts incoming events to each sink's
  own worker. Per-sink processing happens in
  `EvilEngine.Events.SinkWorker` GenServers, supervised by
  `EvilEngine.Events.SinkSupervisor`.

  Properties:

  - `publish/1` is a non-blocking cast to the bus, which then casts to
    every worker. The bus mailbox is never blocked by sink processing.
  - Sinks process events in arrival order per sink (each worker is a
    GenServer); the documented `handle_event(event, state) →
    {:ok, new_state}` in-order state-mutation contract is preserved.
  - Sinks are decoupled from each other — a slow sink's mailbox fills
    independently and does not stall other sinks or the bus.
  - Crash isolation by supervision: a sink that raises crashes only its
    own worker; the supervisor restarts it (one_for_one). A
    `%Event.SinkFailed{}` is emitted before the rescue swallows the
    exception so other sinks can observe the failure.
  """

  use GenServer

  alias EvilEngine.Events.SinkWorker

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Publish a typed event to all registered sinks.
  Always returns `:ok`. Never blocks the caller.
  """
  @spec publish(struct()) :: :ok
  def publish(%{} = event) do
    GenServer.cast(__MODULE__, {:publish, event})
  end

  @doc """
  Register a sink module with initial opts. Called during engine boot
  or from a plugin's `on_load/1`.
  """
  @spec register_sink(String.t(), module(), keyword()) :: :ok | {:error, term()}
  def register_sink(name, module, opts \\ []) do
    GenServer.call(__MODULE__, {:register_sink, name, module, opts})
  end

  @doc "Returns the list of registered sink names and their module."
  @spec list_sinks() :: [%{name: String.t(), module: module()}]
  def list_sinks do
    GenServer.call(__MODULE__, :list_sinks)
  end

  @shutdown_timeout_ms 30_000

  @doc "Trigger graceful shutdown of all sinks (flush buffers)."
  @spec shutdown_sinks() :: :ok
  def shutdown_sinks do
    GenServer.call(__MODULE__, :shutdown_sinks, @shutdown_timeout_ms)
  end

  @doc false
  @spec reset_state() :: :ok
  def reset_state do
    GenServer.call(__MODULE__, :reset_state)
  end

  # --- Server callbacks ---------------------------------------------------

  @impl true
  def init(_opts) do
    {:ok, %{workers: %{}}}
  end

  @impl true
  def handle_call({:register_sink, name, module, opts}, _from, state) do
    if Map.has_key?(state.workers, name) do
      {:reply, {:error, :already_registered}, state}
    else
      child_spec = %{
        id: {SinkWorker, name},
        start: {SinkWorker, :start_link, [{name, module, opts}]},
        restart: :permanent,
        type: :worker
      }

      case DynamicSupervisor.start_child(EvilEngine.Events.SinkSupervisor, child_spec) do
        {:ok, _pid} ->
          {:reply, :ok, %{state | workers: Map.put(state.workers, name, module)}}

        {:error, {:sink_init_failed, reason}} ->
          {:reply, {:error, reason}, state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    end
  end

  @impl true
  def handle_call(:list_sinks, _from, state) do
    result =
      state.workers
      |> Enum.map(fn {name, module} -> %{name: name, module: module} end)
      |> Enum.sort_by(& &1.name)

    {:reply, result, state}
  end

  @impl true
  def handle_call(:reset_state, _from, state) do
    Enum.each(state.workers, fn {name, _module} -> terminate_worker(name) end)
    {:reply, :ok, %{workers: %{}}}
  end

  @impl true
  def handle_call(:shutdown_sinks, _from, state) do
    Enum.each(state.workers, fn {name, _module} ->
      try do
        SinkWorker.shutdown(name)
      catch
        :exit, _ -> :ok
      end
    end)

    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:publish, event}, state) do
    Enum.each(state.workers, fn {name, _module} -> SinkWorker.event(name, event) end)
    {:noreply, state}
  end

  defp terminate_worker(name) do
    case Registry.lookup(EvilEngine.Events.SinkRegistry, name) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(EvilEngine.Events.SinkSupervisor, pid)
      [] -> :ok
    end
  end
end
