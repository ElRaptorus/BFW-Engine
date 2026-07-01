defmodule EvilEngine.Timers.SchedulerTest do
  use ExUnit.Case, async: false

  alias EvilEngine.Timers.Scheduler

  @tick_interval_ms 20

  setup do
    Scheduler.reset_state()
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
      Process.sleep(20)
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
      Process.sleep(100)

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
      Process.sleep(100)

      assert 1 == Scheduler.armed_count()
    end
  end

  # -------------------------------------------------------------------------
  # Cycle timers
  # -------------------------------------------------------------------------

  describe "cycle timers" do
    test "finite cycle re-arms and fires multiple times" do
      {:ok, ref_1} =
        Scheduler.schedule(%{
          fire_at: future(50),
          target: self(),
          metadata: %{cycle_test: true},
          cycle_interval: Duration.new!(second: 1),
          cycle_remaining: 3
        })

      assert_receive {:timer_fired, ^ref_1, %{cycle_test: true}}, 2000

      assert_receive {:timer_fired, ref_2, %{cycle_test: true}}, 2000
      assert ref_2 != ref_1

      assert_receive {:timer_fired, ref_3, %{cycle_test: true}}, 2000
      assert ref_3 != ref_2

      Process.sleep(1500)
      refute_received {:timer_fired, _, %{cycle_test: true}}
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

      {:ok, scheduler} =
        Scheduler.start_link(
          name: scheduler_name,
          tick_interval_ms: @tick_interval_ms,
          on_cycle_advance: {callback_module, :advance, [test_pid]},
          primary_table: :"test_primary_#{unique_id}",
          target_index_table: :"test_target_idx_#{unique_id}"
        )

      on_exit(fn ->
        if Process.alive?(scheduler), do: GenServer.stop(scheduler)
      end)

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

      Scheduler.reset_state()
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
        [:evil_engine, :timer, :armed],
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
        [:evil_engine, :timer, :fired],
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
        [:evil_engine, :timer, :cancelled],
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
  end
end
