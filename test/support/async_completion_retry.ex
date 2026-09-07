defmodule EvilEngine.Test.AsyncCompletionRetry do
  @moduledoc """
  Retries a finish call that raced the PI's transition to `:waiting`.

  `UserTaskCreated` is published from `handle_enter` before the PI applies
  `{:wait}`. Plugin `finish_async` can run before `Registry.register` in
  `do_handle_fni_async`. A single fire-and-forget attempt then leaves the
  FNI waiting forever (E6: `{:timeout, 4999}`). See
  `docs/architecture/testing.md` (ExUnit and CI constraints).
  """

  @retryable_reasons [
    :fni_not_waiting,
    :fni_not_found,
    :not_found,
    :process_instance_not_found
  ]

  @default_deadline_ms 30_000
  @default_sleep_ms 20

  @doc """
  Call `fun` until it returns `:ok` or a non-retryable error, or the deadline elapses.

  `fun` must return `:ok` or `{:error, reason}`.
  """
  @spec until_ok((-> :ok | {:error, term()}), keyword()) :: :ok | {:error, term()}
  def until_ok(fun, opts \\ []) when is_function(fun, 0) do
    deadline_ms = Keyword.get(opts, :deadline_ms, @default_deadline_ms)
    sleep_ms = Keyword.get(opts, :sleep_ms, @default_sleep_ms)
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    do_until_ok(fun, deadline, sleep_ms)
  end

  defp do_until_ok(fun, deadline, sleep_ms) do
    case fun.() do
      :ok ->
        :ok

      {:error, reason} = error ->
        cond do
          reason not in @retryable_reasons ->
            error

          System.monotonic_time(:millisecond) >= deadline ->
            error

          true ->
            Process.sleep(sleep_ms)
            do_until_ok(fun, deadline, sleep_ms)
        end
    end
  end
end
