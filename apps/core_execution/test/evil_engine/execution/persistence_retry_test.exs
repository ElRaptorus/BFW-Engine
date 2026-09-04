defmodule EvilEngine.Execution.PersistenceRetryTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias EvilEngine.Execution.PersistenceRetry

  describe "with_retry/3 happy path" do
    test "returns :ok on first attempt without retrying" do
      counter = :counters.new(1, [:atomics])

      result =
        PersistenceRetry.with_retry(
          fn ->
            :counters.add(counter, 1, 1)
            :ok
          end,
          "test_ok"
        )

      assert result == :ok
      assert :counters.get(counter, 1) == 1
    end

    test "returns {:ok, value} on first attempt without retrying" do
      result =
        PersistenceRetry.with_retry(
          fn -> {:ok, %{id: "abc"}} end,
          "test_ok_tuple"
        )

      assert result == {:ok, %{id: "abc"}}
    end
  end

  describe "with_retry/3 transient failure" do
    test "retries on {:error, _} and succeeds on later attempt" do
      counter = :counters.new(1, [:atomics])

      log =
        capture_log(fn ->
          result =
            PersistenceRetry.with_retry(
              fn ->
                :counters.add(counter, 1, 1)
                attempt = :counters.get(counter, 1)

                if attempt < 3 do
                  {:error, :connection_refused}
                else
                  :ok
                end
              end,
              "test_transient",
              max_attempts: 5,
              initial_backoff_ms: 1
            )

          assert result == :ok
        end)

      assert :counters.get(counter, 1) == 3
      assert log =~ "[PersistenceRetry] test_transient failed (attempt 1/5)"
      assert log =~ "[PersistenceRetry] test_transient failed (attempt 2/5)"
    end

    test "retries and returns {:ok, value} on recovery" do
      counter = :counters.new(1, [:atomics])

      capture_log(fn ->
        result =
          PersistenceRetry.with_retry(
            fn ->
              :counters.add(counter, 1, 1)
              current = :counters.get(counter, 1)

              if current < 2 do
                {:error, :timeout}
              else
                {:ok, :recovered}
              end
            end,
            "test_recovery",
            max_attempts: 3,
            initial_backoff_ms: 1
          )

        assert result == {:ok, :recovered}
      end)

      assert :counters.get(counter, 1) == 2
    end
  end

  describe "with_retry/3 exhaustion" do
    test "returns last {:error, _} after max_attempts" do
      counter = :counters.new(1, [:atomics])

      log =
        capture_log(fn ->
          result =
            PersistenceRetry.with_retry(
              fn ->
                :counters.add(counter, 1, 1)
                {:error, :db_unavailable}
              end,
              "test_exhaustion",
              max_attempts: 3,
              initial_backoff_ms: 1
            )

          assert result == {:error, :db_unavailable}
        end)

      assert :counters.get(counter, 1) == 3

      assert log =~ "[PersistenceRetry] test_exhaustion failed (attempt 1/3)"
      assert log =~ "[PersistenceRetry] test_exhaustion failed (attempt 2/3)"

      assert log =~
               "[PersistenceRetry] test_exhaustion failed after 3/3 attempts: :db_unavailable"
    end

    test "with max_attempts=1, no retry — returns error immediately" do
      counter = :counters.new(1, [:atomics])

      log =
        capture_log(fn ->
          result =
            PersistenceRetry.with_retry(
              fn ->
                :counters.add(counter, 1, 1)
                {:error, :nope}
              end,
              "test_single",
              max_attempts: 1,
              initial_backoff_ms: 1
            )

          assert result == {:error, :nope}
        end)

      assert :counters.get(counter, 1) == 1
      assert log =~ "failed after 1/1 attempts"
    end
  end

  describe "with_retry/3 non-retryable invalid" do
    test "does not retry errors whose reason carries class: :invalid" do
      counter = :counters.new(1, [:atomics])
      invalid = %{class: :invalid, message: "no such input"}

      log =
        capture_log(fn ->
          result =
            PersistenceRetry.with_retry(
              fn ->
                :counters.add(counter, 1, 1)
                {:error, invalid}
              end,
              "test_invalid",
              max_attempts: 5,
              initial_backoff_ms: 50
            )

          assert result == {:error, invalid}
        end)

      assert :counters.get(counter, 1) == 1
      assert log =~ "[PersistenceRetry] test_invalid failed with non-retryable error"
      refute log =~ "retrying in"
    end
  end

  describe "with_retry/3 reads config defaults" do
    test "uses application env for max_attempts when not overridden" do
      previous = Application.get_env(:core_execution, :persistence_retry_max_attempts)
      Application.put_env(:core_execution, :persistence_retry_max_attempts, 2)

      counter = :counters.new(1, [:atomics])

      capture_log(fn ->
        PersistenceRetry.with_retry(
          fn ->
            :counters.add(counter, 1, 1)
            {:error, :fail}
          end,
          "test_config",
          initial_backoff_ms: 1
        )
      end)

      assert :counters.get(counter, 1) == 2

      if previous do
        Application.put_env(:core_execution, :persistence_retry_max_attempts, previous)
      else
        Application.delete_env(:core_execution, :persistence_retry_max_attempts)
      end
    end
  end
end
