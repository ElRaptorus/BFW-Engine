defmodule BfwEngine.Timers.SchedulerTest do
  use ExUnit.Case, async: false

  alias BfwEngine.Timers.Scheduler
  alias BfwEngine.Timers.ServiceReset

  @tick_interval_ms 20

  setup do
    ServiceReset.scheduler()
    :ok
  end

  defp future(milliseconds) do
    DateTime.add(DateTime.utc_now(), milliseconds, :millisecond)
  end

  defp past(milliseconds) do
    DateTime.add(DateTime.utc_now(), -milliseconds, :millisecond)
  end

  # -------------------------------------------------------------------------
  # schedule/1 + fire
  # -------------------------------------------------------------------------

  describe "schedule + fire" do
    test "schedules a timer and fires it to a PID target" do
      {:ok, timer_ref} =
        Scheduler.schedule(%{
          fire_at: future(50),
          target: self(),
          metadata: %{test: "hello"}
        })

      assert is_binary(timer_ref)
      assert_receive {:timer_fired, ^timer_ref, %{test: "hello"}}, 500
    end

    test "fires immediately for a past fire_at" do
      {:ok, timer_ref} =
        Scheduler.schedule(%{
          fire_at: past(5000),
          target: self(),
          metadata: %{past: true}
        })

      assert_receive {:timer_fired, ^timer_ref, %{past: true}}, 200
    end

    test "fires multiple timers in order" do
      {:ok, ref_1} =
        Scheduler.schedule(%{fire_at: future(60), target: self(), metadata: %{order: 1}})

      {:ok, ref_2} =
        Scheduler.schedule(%{fire_at: future(120), target: self(), metadata: %{order: 2}})

      assert_receive {:timer_fired, ^ref_1, %{order: 1}}, 500
      assert_receive {:timer_fired, ^ref_2, %{order: 2}}, 500
    end

    test "delivers to atom target via Process.whereis" do
      test_pid = self()

      receiver =
        spawn(fn ->
          receive do
            {:timer_fired, _ref, metadata} ->
              send(test_pid, {:received_fire, metadata})
          after
            2000 -> :timeout
          end
        end)

      Process.register(receiver, :scheduler_atom_target_test_receiver)

      {:ok, _ref} =
        Scheduler.schedule(%{
          fire_at: future(50),
          target: :scheduler_atom_target_test_receiver,
          metadata: %{atom_target: true}
        })

      assert_receive {:received_fire, %{atom_target: true}}, 500
    end

    test "silently drops fire for dead PID target" do
      dead_pid = spawn(fn -> :ok end)
      dead_reference = Process.monitor(dead_pid)
      assert_receive {:DOWN, ^dead_reference, :process, ^dead_pid, _}, 200
      refute Process.alive?(dead_pid)

      {:ok, _ref} =
        Scheduler.schedule(%{
          fire_at: future(50),
          target: dead_pid,
          metadata: %{dead: true}
        })

      Process.sleep(200)
      refute_received {:timer_fired, _, _}
    end
  end

  # -------------------------------------------------------------------------
  # cancel/1
  # -------------------------------------------------------------------------

  describe "cancel/1" do
    test "cancels an existing timer" do
      {:ok, timer_ref} =
        Scheduler.schedule(%{
          fire_at: future(5000),
          target: self(),
          metadata: %{should_not_fire: true}
        })

      assert :ok = Scheduler.cancel(timer_ref)
      assert Scheduler.armed_count() == 0
    end

    test "returns :not_found for unknown ref" do
      assert {:error, :not_found} = Scheduler.cancel("nonexistent-ref")
    end

    test "cancelled timer does not fire" do
      {:ok, timer_ref} =
        Scheduler.schedule(%{
          fire_at: future(80),
          target: self(),
          metadata: %{cancelled: true}
        })

      Scheduler.cancel(timer_ref)
      Process.sleep(200)
      refute_received {:timer_fired, ^timer_ref, _}
    end
  end

  # -------------------------------------------------------------------------
  # cancel_all_for_target/1
  # -------------------------------------------------------------------------

  describe "cancel_all_for_target/1" do
    test "cancels all timers for a PID target" do
      {:ok, _ref_1} =
        Scheduler.schedule(%{fire_at: future(5000), target: self(), metadata: %{a: 1}})

      {:ok, _ref_2} =
        Scheduler.schedule(%{fire_at: future(5000), target: self(), metadata: %{a: 2}})

      {:ok, _ref_3} =
        Scheduler.schedule(%{fire_at: future(5000), target: self(), metadata: %{a: 3}})

      assert 3 == Scheduler.cancel_all_for_target(self())
      assert 0 == Scheduler.armed_count()
    end

    test "returns 0 when no timers exist for target" do
      assert 0 == Scheduler.cancel_all_for_target(self())
    end

    test "stops monitoring the target" do
      {:ok, _ref} = Scheduler.schedule(%{fire_at: future(5000), target: self(), metadata: %{}})
      scheduler_pid = Process.whereis(Scheduler)
      {:monitors, monitors_before} = Process.info(scheduler_pid, :monitors)
      assert {:process, self()} in monitors_before

      assert 1 == Scheduler.cancel_all_for_target(self())

      {:monitors, monitors_after} = Process.info(scheduler_pid, :monitors)
      refute {:process, self()} in monitors_after
    end

    test "does not cancel timers for other targets" do
      other_pid = spawn(fn -> Process.sleep(60_000) end)
      on_exit(fn -> Process.exit(other_pid, :kill) end)

      {:ok, _ref_1} = Scheduler.schedule(%{fire_at: future(5000), target: self(), metadata: %{}})

      {:ok, _ref_2} =
        Scheduler.schedule(%{fire_at: future(5000), target: other_pid, metadata: %{}})

      assert 1 == Scheduler.cancel_all_for_target(self())
      assert 1 == Scheduler.armed_count()
    end
  end

  # -------------------------------------------------------------------------
  # armed_count/0
  # -------------------------------------------------------------------------

  describe "armed_count/0" do
    test "returns 0 when no timers scheduled" do
      assert 0 == Scheduler.armed_count()
    end

    test "reflects scheduled timers" do
      {:ok, _ref} = Scheduler.schedule(%{fire_at: future(60_000), target: self(), metadata: %{}})
      assert 1 == Scheduler.armed_count()

      {:ok, _ref_2} =
        Scheduler.schedule(%{fire_at: future(60_000), target: self(), metadata: %{}})

      assert 2 == Scheduler.armed_count()
    end

    test "decrements after fire" do
      {:ok, ref} = Scheduler.schedule(%{fire_at: future(50), target: self(), metadata: %{}})
      assert_receive {:timer_fired, ^ref, _}, 500
      assert 0 == Scheduler.armed_count()
    end
  end

  # -------------------------------------------------------------------------
  # PID monitoring (auto-cancel on DOWN)
  # -------------------------------------------------------------------------

  describe "PID monitoring" do
    test "auto-cancels timers when target PID dies" do
      target = spawn(fn -> Process.sleep(60_000) end)

      {:ok, _ref} = Scheduler.schedule(%{fire_at: future(60_000), target: target, metadata: %{}})

      {:ok, _ref_2} =
        Scheduler.schedule(%{fire_at: future(60_000), target: target, metadata: %{}})

      assert 2 == Scheduler.armed_count()

      Process.exit(target, :kill)
      assert :ok = wait_until_armed_count(0)

      assert 0 == Scheduler.armed_count()
    end

    test "does not affect timers for other targets when one PID dies" do
      target_a = spawn(fn -> Process.sleep(60_000) end)
      target_b = spawn(fn -> Process.sleep(60_000) end)
      on_exit(fn -> Process.exit(target_b, :kill) end)

      {:ok, _ref_a} =
        Scheduler.schedule(%{fire_at: future(60_000), target: target_a, metadata: %{}})

      {:ok, _ref_b} =
        Scheduler.schedule(%{fire_at: future(60_000), target: target_b, metadata: %{}})

      Process.exit(target_a, :kill)
      assert :ok = wait_until_armed_count(1)

      assert 1 == Scheduler.armed_count()
    end
  end

  # -------------------------------------------------------------------------
  # Cycle timers
  # -------------------------------------------------------------------------

  describe "cycle timers" do
    test "finite cycle re-arms under the same ref and fires multiple times" do
      {:ok, timer_ref} =
        Scheduler.schedule(%{
          fire_at: future(50),
          target: self(),
          metadata: %{cycle_test: true},
          cycle_interval: Duration.new!(second: 1),
          cycle_remaining: 3
        })

      for _i <- 1..3 do
        assert_receive {:timer_fired, ^timer_ref, %{cycle_test: true}}, 2000
      end

      Process.sleep(1500)
      refute_received {:timer_fired, _, %{cycle_test: true}}
    end

    test "the ref returned by schedule cancels a cycle that has already fired" do
      {:ok, timer_ref} =
        Scheduler.schedule(%{
          fire_at: future(50),
          target: self(),
          metadata: %{cancel_after_fire: true},
          cycle_interval: Duration.new!(second: 1),
          cycle_remaining: :infinite
        })

      assert_receive {:timer_fired, ^timer_ref, %{cancel_after_fire: true}}, 2000
      assert :ok = Scheduler.cancel(timer_ref)

      refute_receive {:timer_fired, _, %{cancel_after_fire: true}}, 1500
    end

    test "infinite cycle keeps firing" do
      {:ok, _ref} =
        Scheduler.schedule(%{
          fire_at: future(50),
          target: self(),
          metadata: %{infinite: true},
          cycle_interval: Duration.new!(second: 1),
          cycle_remaining: :infinite
        })

      for _i <- 1..3 do
        assert_receive {:timer_fired, _, %{infinite: true}}, 2000
      end

      Scheduler.cancel_all_for_target(self())
    end

    test "cycle invokes on_cycle_advance callback" do
      test_pid = self()
      unique_id = System.unique_integer([:positive])

      callback_module = Module.concat([__MODULE__, "CycleCallback#{unique_id}"])

      defmodule callback_module do
        def advance(metadata, next_fire, remaining, extra) do
          send(extra, {:cycle_advanced, metadata, next_fire, remaining})
        end
      end

      scheduler_name = :"test_scheduler_cycle_#{unique_id}"

      scheduler =
        start_supervised!(
          {Scheduler,
           name: scheduler_name,
           tick_interval_ms: @tick_interval_ms,
           on_cycle_advance: {callback_module, :advance, [test_pid]},
           primary_table: :"test_primary_#{unique_id}",
           target_index_table: :"test_target_idx_#{unique_id}"}
        )

      {:ok, _ref} =
        Scheduler.schedule(
          %{
            fire_at: future(50),
            target: self(),
            metadata: %{schedule_id: "test-123"},
            cycle_interval: Duration.new!(second: 1),
            cycle_remaining: 2
          },
          scheduler
        )

      assert_receive {:timer_fired, _, _}, 2000
      assert_receive {:cycle_advanced, %{schedule_id: "test-123"}, next_fire, 1}, 2000
      assert %DateTime{} = next_fire

      assert_receive {:timer_fired, _, _}, 2000
      assert_receive {:cycle_advanced, %{schedule_id: "test-123"}, nil, 0}, 2000
    end

    test "a cycle overdue by several intervals fires once and re-arms the next future occurrence" do
      scheduler =
        start_callback_scheduler(fn metadata, next_fire, remaining, test_pid ->
          send(test_pid, {:cycle_advanced, metadata, next_fire, remaining})
        end)

      overdue_since =
        DateTime.utc_now()
        |> DateTime.truncate(:second)
        |> DateTime.add(-(5 * 3600 + 60), :second)

      {:ok, timer_ref} =
        Scheduler.schedule(
          %{
            fire_at: overdue_since,
            target: self(),
            metadata: %{catch_up: true},
            cycle_interval: Duration.new!(hour: 1),
            cycle_remaining: 10
          },
          scheduler
        )

      assert_receive {:timer_fired, ^timer_ref, %{catch_up: true}}, 1_000
      assert_receive {:cycle_advanced, %{catch_up: true}, next_fire, 4}, 1_000
      assert DateTime.compare(next_fire, DateTime.add(overdue_since, 6 * 3600, :second)) == :eq
      refute_receive {:timer_fired, ^timer_ref, _metadata}, 300
      assert Scheduler.armed_count(scheduler) == 1
    end

    test "a finite cycle whose remaining occurrences are all overdue ends after one fire" do
      scheduler =
        start_callback_scheduler(fn metadata, next_fire, remaining, test_pid ->
          send(test_pid, {:cycle_advanced, metadata, next_fire, remaining})
        end)

      {:ok, timer_ref} =
        Scheduler.schedule(
          %{
            fire_at: past(5 * 3600 * 1000),
            target: self(),
            metadata: %{exhausted: true},
            cycle_interval: Duration.new!(hour: 1),
            cycle_remaining: 3
          },
          scheduler
        )

      assert_receive {:timer_fired, ^timer_ref, %{exhausted: true}}, 1_000
      assert_receive {:cycle_advanced, %{exhausted: true}, nil, 0}, 1_000
      refute_received {:timer_fired, ^timer_ref, _metadata}
      refute_received {:cycle_advanced, %{exhausted: true}, _next_fire, _remaining}
      assert Scheduler.armed_count(scheduler) == 0
    end

    test "a slow on_cycle_advance callback does not block the Scheduler" do
      scheduler =
        start_callback_scheduler(fn _metadata, _next_fire, _remaining, test_pid ->
          send(test_pid, :slow_callback_started)
          Process.sleep(3_000)
        end)

      {:ok, timer_ref} =
        Scheduler.schedule(
          %{
            fire_at: future(20),
            target: self(),
            metadata: %{},
            cycle_interval: Duration.new!(hour: 1),
            cycle_remaining: :infinite
          },
          scheduler
        )

      assert_receive {:timer_fired, ^timer_ref, _metadata}, 1_000
      assert_receive :slow_callback_started, 1_000

      {elapsed_microseconds, armed_count} =
        :timer.tc(fn -> Scheduler.armed_count(scheduler) end)

      assert armed_count == 1
      assert elapsed_microseconds < 1_000_000
    end

    test "a callback that throws does not lose the cycle advances queued behind it" do
      scheduler =
        start_callback_scheduler(fn metadata, _next_fire, _remaining, test_pid ->
          send(test_pid, {:cycle_advanced, metadata})
          if metadata.cycle == :first, do: Process.sleep(400)
          throw(:callback_failed)
        end)

      schedule_two_cycles(scheduler, first: 20, second: 150)

      assert_receive {:cycle_advanced, %{cycle: :first}}, 1_000
      assert_receive {:cycle_advanced, %{cycle: :second}}, 1_000
    end

    test "a cycle advance worker that dies is replaced" do
      scheduler =
        start_callback_scheduler(fn metadata, _next_fire, _remaining, test_pid ->
          send(test_pid, {:cycle_advanced, metadata})
          if metadata.cycle == :first, do: Process.exit(self(), :kill)
        end)

      schedule_two_cycles(scheduler, first: 20, second: 300)

      assert_receive {:cycle_advanced, %{cycle: :first}}, 1_000
      assert_receive {:cycle_advanced, %{cycle: :second}}, 1_000
    end
  end

  describe "restart after a crash" do
    test "invokes on_restart only when the previous Scheduler did not shut down cleanly" do
      test_pid = self()
      unique_id = System.unique_integer([:positive])
      scheduler_name = :"restart_test_scheduler_#{unique_id}"

      child_spec =
        Supervisor.child_spec(
          {Scheduler,
           name: scheduler_name,
           tick_interval_ms: @tick_interval_ms,
           primary_table: :"restart_test_primary_#{unique_id}",
           target_index_table: :"restart_test_target_index_#{unique_id}",
           on_restart: {Kernel, :send, [test_pid, :restore_requested]}},
          id: scheduler_name
        )

      start_supervised!(child_spec)
      refute_receive :restore_requested, 200

      :ok = stop_supervised(scheduler_name)
      start_supervised!(child_spec)
      refute_receive :restore_requested, 200

      Process.exit(Process.whereis(scheduler_name), :kill)
      assert_receive :restore_requested, 2_000
    end

    test "retries a failing restore with backoff until it succeeds" do
      unique_id = System.unique_integer([:positive])
      scheduler_name = :"restore_retry_scheduler_#{unique_id}"
      attempt_counter = :counters.new(1, [])

      start_supervised!(
        {Scheduler,
         name: scheduler_name,
         tick_interval_ms: @tick_interval_ms,
         primary_table: :"restore_retry_primary_#{unique_id}",
         target_index_table: :"restore_retry_target_index_#{unique_id}",
         on_restart: {__MODULE__, :restore_succeeding_on_third_attempt, [self(), attempt_counter]}}
      )

      Process.exit(Process.whereis(scheduler_name), :kill)

      assert_receive {:restored, 3}, 4_000
    end
  end

  def restore_succeeding_on_third_attempt(test_pid, attempt_counter) do
    :counters.add(attempt_counter, 1, 1)

    case :counters.get(attempt_counter, 1) do
      1 -> raise "database unavailable"
      2 -> {:error, :database_unavailable}
      attempt -> send(test_pid, {:restored, attempt})
    end
  end

  # -------------------------------------------------------------------------
  # reset_state/0
  # -------------------------------------------------------------------------

  describe "reset_state/0" do
    test "clears all timers" do
      {:ok, _ref} = Scheduler.schedule(%{fire_at: future(60_000), target: self(), metadata: %{}})

      {:ok, _ref_2} =
        Scheduler.schedule(%{fire_at: future(60_000), target: self(), metadata: %{}})

      assert 2 == Scheduler.armed_count()

      ServiceReset.scheduler()
      assert 0 == Scheduler.armed_count()
    end
  end

  # -------------------------------------------------------------------------
  # Telemetry emissions
  # -------------------------------------------------------------------------

  describe "telemetry" do
    test "emits :armed telemetry on schedule" do
      telemetry_ref = make_ref()
      test_pid = self()

      :telemetry.attach(
        "test-armed-#{inspect(telemetry_ref)}",
        [:bfw_engine, :timer, :armed],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:telemetry_armed, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach("test-armed-#{inspect(telemetry_ref)}") end)

      {:ok, timer_ref} =
        Scheduler.schedule(%{fire_at: future(60_000), target: self(), metadata: %{tel: true}})

      assert_receive {:telemetry_armed, measurements, %{tel: true}}, 500
      assert measurements.timer_ref == timer_ref
      assert %DateTime{} = measurements.fire_at
    end

    test "emits :fired telemetry on fire" do
      telemetry_ref = make_ref()
      test_pid = self()

      :telemetry.attach(
        "test-fired-#{inspect(telemetry_ref)}",
        [:bfw_engine, :timer, :fired],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:telemetry_fired, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach("test-fired-#{inspect(telemetry_ref)}") end)

      {:ok, timer_ref} =
        Scheduler.schedule(%{fire_at: future(50), target: self(), metadata: %{fire_tel: true}})

      assert_receive {:timer_fired, ^timer_ref, _}, 500
      assert_receive {:telemetry_fired, measurements, %{fire_tel: true}}, 500
      assert measurements.timer_ref == timer_ref
    end

    test "emits :cancelled telemetry on cancel" do
      telemetry_ref = make_ref()
      test_pid = self()

      :telemetry.attach(
        "test-cancelled-#{inspect(telemetry_ref)}",
        [:bfw_engine, :timer, :cancelled],
        fn _event, measurements, _metadata, _config ->
          send(test_pid, {:telemetry_cancelled, measurements})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach("test-cancelled-#{inspect(telemetry_ref)}") end)

      {:ok, timer_ref} =
        Scheduler.schedule(%{fire_at: future(60_000), target: self(), metadata: %{}})

      Scheduler.cancel(timer_ref)

      assert_receive {:telemetry_cancelled, measurements}, 500
      assert measurements.timer_ref == timer_ref
    end

    test "emits :cancelled telemetry for every timer of cancel_all_for_target" do
      telemetry_ref = make_ref()
      test_pid = self()

      :telemetry.attach(
        "test-cancelled-all-#{inspect(telemetry_ref)}",
        [:bfw_engine, :timer, :cancelled],
        fn _event, measurements, _metadata, _config ->
          send(test_pid, {:telemetry_cancelled, measurements.timer_ref})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach("test-cancelled-all-#{inspect(telemetry_ref)}") end)

      timer_refs =
        for _ <- 1..2 do
          {:ok, timer_ref} =
            Scheduler.schedule(%{fire_at: future(60_000), target: self(), metadata: %{}})

          timer_ref
        end

      assert 2 == Scheduler.cancel_all_for_target(self())

      for timer_ref <- timer_refs do
        assert_receive {:telemetry_cancelled, ^timer_ref}, 500
      end
    end
  end

  defmodule CycleAdvanceRelay do
    @moduledoc false
    def advance(metadata, next_fire, remaining, callback, test_pid),
      do: callback.(metadata, next_fire, remaining, test_pid)
  end

  defp start_callback_scheduler(callback) do
    unique_id = System.unique_integer([:positive])
    scheduler_name = :"test_scheduler_callback_#{unique_id}"

    start_supervised!(
      {Scheduler,
       name: scheduler_name,
       tick_interval_ms: @tick_interval_ms,
       on_cycle_advance: {CycleAdvanceRelay, :advance, [callback, self()]},
       primary_table: :"test_primary_callback_#{unique_id}",
       target_index_table: :"test_target_index_callback_#{unique_id}"}
    )

    scheduler_name
  end

  defp schedule_two_cycles(scheduler, delays_ms) do
    for {cycle, delay_ms} <- delays_ms do
      {:ok, _timer_ref} =
        Scheduler.schedule(
          %{
            fire_at: future(delay_ms),
            target: self(),
            metadata: %{cycle: cycle},
            cycle_interval: Duration.new!(hour: 1),
            cycle_remaining: :infinite
          },
          scheduler
        )
    end
  end

  defp wait_until_armed_count(expected_count, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_until_armed_count(expected_count, deadline)
  end

  defp do_wait_until_armed_count(expected_count, deadline) do
    if Scheduler.armed_count() == expected_count do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        {:error, {:scheduler_wait_timeout, Scheduler.armed_count()}}
      else
        Process.sleep(20)
        do_wait_until_armed_count(expected_count, deadline)
      end
    end
  end
end
