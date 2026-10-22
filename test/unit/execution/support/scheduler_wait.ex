defmodule BfwEngine.Execution.TestSupport.SchedulerWait do
  @moduledoc """
  Poll the timer Scheduler instead of `Process.sleep` in tests.

  Arming, firing, and cancelling are asynchronous. A fixed sleep either
  races (the timer has not armed yet) or wastes time. Poll `armed_count/0`
  or an arbitrary predicate until the condition holds.
  """

  alias BfwEngine.Timers.Scheduler

  @default_timeout_ms 2_000
  @poll_interval_ms 20

  @spec wait_until_armed(non_neg_integer(), pos_integer()) :: :ok | {:error, :timeout}
  def wait_until_armed(minimum_count, timeout \\ @default_timeout_ms) do
    wait_until(fn -> Scheduler.armed_count() >= minimum_count end, timeout)
  end

  @spec wait_until_count(non_neg_integer(), pos_integer()) :: :ok | {:error, :timeout}
  def wait_until_count(expected_count, timeout \\ @default_timeout_ms) do
    wait_until(fn -> Scheduler.armed_count() == expected_count end, timeout)
  end

  @spec wait_until_below(non_neg_integer(), pos_integer()) :: :ok | {:error, :timeout}
  def wait_until_below(maximum_count, timeout \\ @default_timeout_ms) do
    wait_until(fn -> Scheduler.armed_count() < maximum_count end, timeout)
  end

  @spec wait_until((-> boolean()), pos_integer()) :: :ok | {:error, :timeout}
  def wait_until(predicate, timeout \\ @default_timeout_ms) when is_function(predicate, 0) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_until(predicate, deadline)
  end

  defp do_wait_until(predicate, deadline) do
    if predicate.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        {:error, :timeout}
      else
        Process.sleep(@poll_interval_ms)
        do_wait_until(predicate, deadline)
      end
    end
  end
end
