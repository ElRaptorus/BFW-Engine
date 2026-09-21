defmodule BfwEngine.Load.AsyncCompletionRetryTest do
  use ExUnit.Case, async: true

  alias BfwEngine.Test.AsyncCompletionRetry

  @tag :load
  test "retries retryable errors then returns :ok" do
    {:ok, remaining} = Agent.start_link(fn -> 3 end)

    assert :ok =
             AsyncCompletionRetry.until_ok(
               fn ->
                 left = Agent.get_and_update(remaining, fn count -> {count, count - 1} end)

                 if left > 0 do
                   {:error, :fni_not_waiting}
                 else
                   :ok
                 end
               end,
               deadline_ms: 1_000,
               sleep_ms: 1
             )
  end

  @tag :load
  test "does not retry a non-retryable error" do
    assert {:error, :fni_already_finished} =
             AsyncCompletionRetry.until_ok(fn -> {:error, :fni_already_finished} end,
               deadline_ms: 50,
               sleep_ms: 1
             )
  end
end
