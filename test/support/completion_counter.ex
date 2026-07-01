defmodule EvilEngine.Test.CompletionCounter do
  @moduledoc """
  Counts PI completions via telemetry for load test synchronization.

  Uses `:atomics` for lock-free, concurrent-safe counting. Attaches a
  telemetry handler on `[:evil_engine, :process_instance, :state_change]` that
  increments when a PI reaches a terminal state (`:finished` or `:fatal`).
  """

  @terminal_states [:finished, :fatal]

  @doc """
  Start a new counter. Returns a handle used by `count/1`, `await/3`, and `stop/1`.
  """
  @spec start() :: map()
  def start do
    ref = :atomics.new(1, signed: false)
    handler_id = "completion-counter-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:evil_engine, :process_instance, :state_change],
      fn _event, _measurements, metadata, config ->
        if metadata.new_state in @terminal_states do
          :atomics.add(config.ref, 1, 1)
        end
      end,
      %{ref: ref}
    )

    %{ref: ref, handler_id: handler_id}
  end

  @doc "Read the current completion count."
  @spec count(map()) :: non_neg_integer()
  def count(%{ref: ref}), do: :atomics.get(ref, 1)

  @doc """
  Block until `target` completions are reached or `timeout_ms` elapses.

  Returns `{:ok, count}` on success, `{:timeout, count}` if the deadline
  is reached before the target.
  """
  @spec await(map(), pos_integer(), pos_integer()) :: {:ok, non_neg_integer()} | {:timeout, non_neg_integer()}
  def await(handle, target, timeout_ms \\ 60_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll(handle, target, deadline)
  end

  defp poll(handle, target, deadline) do
    current = count(handle)

    cond do
      current >= target ->
        {:ok, current}

      System.monotonic_time(:millisecond) >= deadline ->
        {:timeout, current}

      true ->
        Process.sleep(10)
        poll(handle, target, deadline)
    end
  end

  @doc "Detach the telemetry handler and clean up."
  @spec stop(map()) :: :ok
  def stop(%{handler_id: handler_id}) do
    :telemetry.detach(handler_id)
    :ok
  end
end
