defmodule EvilEngine.Execution.PersistenceRetry do
  @moduledoc """
  Bounded retry with exponential backoff for persistence adapter calls.

  Wraps any `() -> :ok | {:ok, term()} | {:error, term()}` function and
  retries on `{:error, _}` return values with exponential backoff plus
  jitter. Successful returns (`:ok`, `{:ok, _}`) are passed through
  immediately.

  ## Configuration

  - `:core_execution, :persistence_retry_max_attempts` — max attempts
    before returning the last error (default: `5`).
  - `:core_execution, :persistence_retry_initial_backoff_ms` — base
    backoff in milliseconds; each subsequent attempt doubles it
    (default: `100`).

  ## Backoff formula

      sleep_ms = initial_backoff_ms * 2^(attempt - 1) + :rand.uniform(51) - 1

  With defaults (5 attempts, 100ms initial), worst-case total wait is
  ~3.1s (100 + 200 + 400 + 800 + 1600 + jitter).

  ## Where it runs

  Retry runs in the calling process. For PI-level calls this is the
  `:gen_statem` process; for `FniLifecycle.finish/4` this is the handler
  Task. `Process.sleep/1` yields the BEAM scheduler — no busy-waiting.
  """

  require Logger

  @spec with_retry(
          (-> :ok | {:ok, term()} | {:error, term()}),
          String.t(),
          keyword()
        ) :: :ok | {:ok, term()} | {:error, term()}
  def with_retry(fun, label, opts \\ []) do
    max_attempts =
      Keyword.get_lazy(opts, :max_attempts, fn ->
        Application.get_env(:core_execution, :persistence_retry_max_attempts, 5)
      end)

    initial_backoff_ms =
      Keyword.get_lazy(opts, :initial_backoff_ms, fn ->
        Application.get_env(:core_execution, :persistence_retry_initial_backoff_ms, 100)
      end)

    do_retry(fun, label, 1, max_attempts, initial_backoff_ms)
  end

  defp do_retry(fun, label, attempt, max_attempts, initial_backoff_ms) do
    case fun.() do
      :ok ->
        :ok

      {:ok, _} = success ->
        success

      {:error, reason} = error when attempt >= max_attempts ->
        Logger.error(
          "[PersistenceRetry] #{label} failed after #{attempt}/#{max_attempts} attempts: #{inspect(reason)}"
        )

        error

      {:error, reason} ->
        backoff_ms = compute_backoff(attempt, initial_backoff_ms)

        Logger.warning(
          "[PersistenceRetry] #{label} failed (attempt #{attempt}/#{max_attempts}), " <>
            "retrying in #{backoff_ms}ms: #{inspect(reason)}"
        )

        Process.sleep(backoff_ms)
        do_retry(fun, label, attempt + 1, max_attempts, initial_backoff_ms)
    end
  end

  defp compute_backoff(attempt, initial_backoff_ms) do
    base = initial_backoff_ms * Integer.pow(2, attempt - 1)
    jitter = :rand.uniform(51) - 1
    base + jitter
  end
end
