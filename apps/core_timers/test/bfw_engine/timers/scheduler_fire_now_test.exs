defmodule BfwEngine.Timers.SchedulerFireNowTest do
  use ExUnit.Case, async: false

  alias BfwEngine.Timers.Scheduler

  setup do
    Scheduler.reset_state()
    :ok
  end

  defp future(milliseconds) do
    DateTime.add(DateTime.utc_now(), milliseconds, :millisecond)
  end

  describe "fire_now_for_target/1" do
    test "fires all pending timers for a target PID and returns count" do
      {:ok, timer_ref_1} =
        Scheduler.schedule(%{
          fire_at: future(60_000),
          target: self(),
          metadata: %{index: 1}
        })

      {:ok, timer_ref_2} =
        Scheduler.schedule(%{
          fire_at: future(120_000),
          target: self(),
          metadata: %{index: 2}
        })

      assert 2 == Scheduler.armed_count()
      assert 2 == Scheduler.fire_now_for_target(self())
      assert 0 == Scheduler.armed_count()

      assert_receive {:timer_fired, ^timer_ref_1, %{index: 1}}
      assert_receive {:timer_fired, ^timer_ref_2, %{index: 2}}
    end

    test "returns 0 when no timers exist for the target" do
      assert 0 == Scheduler.fire_now_for_target(self())
    end

    test "delivers {:timer_fired, timer_ref, metadata} messages to the target" do
      metadata = %{manual_trigger: true, flow_node_instance_id: "fni-123"}

      {:ok, timer_ref} =
        Scheduler.schedule(%{
          fire_at: future(60_000),
          target: self(),
          metadata: metadata
        })

      assert 1 == Scheduler.fire_now_for_target(self())
      assert_receive {:timer_fired, ^timer_ref, ^metadata}
    end

    test "does not fire timers for other targets" do
      other_pid = spawn(fn -> Process.sleep(60_000) end)
      on_exit(fn -> Process.exit(other_pid, :kill) end)

      {:ok, own_timer_ref} =
        Scheduler.schedule(%{
          fire_at: future(60_000),
          target: self(),
          metadata: %{target: :self}
        })

      {:ok, other_timer_ref} =
        Scheduler.schedule(%{
          fire_at: future(60_000),
          target: other_pid,
          metadata: %{target: :other}
        })

      assert 1 == Scheduler.fire_now_for_target(self())
      assert 1 == Scheduler.armed_count()

      assert_receive {:timer_fired, ^own_timer_ref, %{target: :self}}
      refute_received {:timer_fired, ^other_timer_ref, _}

      Scheduler.cancel_all_for_target(other_pid)
    end

    test "fires timers regardless of their scheduled fire time" do
      {:ok, timer_ref} =
        Scheduler.schedule(%{
          fire_at: future(300_000),
          target: self(),
          metadata: %{far_future: true}
        })

      refute_receive {:timer_fired, ^timer_ref, _}, 50

      assert 1 == Scheduler.fire_now_for_target(self())
      assert_receive {:timer_fired, ^timer_ref, %{far_future: true}}
    end
  end
end
