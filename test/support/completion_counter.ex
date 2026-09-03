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

  ## Options

    * `:roots_only` — when `true`, count only root process instances whose
      `parent_process_instance_id` is `nil`, `:undefined`, or absent from
      telemetry metadata. Defaults to `false` so child PIs (e.g. Call Activity)
      are included.
  """
  @spec start(keyword()) :: map()
  def start, do: start([])

  def start(opts) do
    roots_only = Keyword.get(opts, :roots_only, false)
    ref = :atomics.new(1, signed: false)
    handler_id = "completion-counter-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:evil_engine, :process_instance, :state_change],
      fn _event, _measurements, metadata, config ->
        if metadata.new_state in @terminal_states and
             counts_as_completion?(metadata, config.roots_only) do
          :atomics.add(config.ref, 1, 1)
        end
      end,
      %{ref: ref, roots_only: roots_only}
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

  defp counts_as_completion?(_metadata, false), do: true

  defp counts_as_completion?(metadata, true) do
    case Map.fetch(metadata, :parent_process_instance_id) do
      {:ok, parent_process_instance_id}
      when parent_process_instance_id in [nil, :undefined] ->
        true

      :error ->
        true

      {:ok, _parent_process_instance_id} ->
        false
    end
  end
end
