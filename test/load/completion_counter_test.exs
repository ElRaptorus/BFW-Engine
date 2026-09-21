defmodule BfwEngine.Load.CompletionCounterTest do
  use ExUnit.Case, async: false

  alias BfwEngine.Test.CompletionCounter

  @event [:bfw_engine, :process_instance, :state_change]
  @child_parent_id "00000000-0000-0000-0000-000000000001"

  defp emit_state_change(metadata) do
    base_metadata = %{
      process_instance_id: Ecto.UUID.generate(),
      old_state: :running,
      new_state: :finished
    }

    :telemetry.execute(
      @event,
      %{system_time: System.system_time()},
      Map.merge(base_metadata, metadata)
    )
  end

  @tag :load
  test "roots_only counts only root terminal process instances" do
    counter = CompletionCounter.start(roots_only: true)

    try do
      emit_state_change(%{parent_process_instance_id: nil})
      emit_state_change(%{parent_process_instance_id: @child_parent_id})

      assert CompletionCounter.count(counter) == 1
    after
      CompletionCounter.stop(counter)
    end
  end

  @tag :load
  test "default start counts all terminal process instances including children" do
    counter = CompletionCounter.start()

    try do
      emit_state_change(%{parent_process_instance_id: nil})
      emit_state_change(%{parent_process_instance_id: @child_parent_id})

      assert CompletionCounter.count(counter) == 2
    after
      CompletionCounter.stop(counter)
    end
  end

  @tag :load
  test "roots_only treats missing parent_process_instance_id as root" do
    counter = CompletionCounter.start(roots_only: true)

    try do
      emit_state_change(%{})
      emit_state_change(%{parent_process_instance_id: @child_parent_id})

      assert CompletionCounter.count(counter) == 1
    after
      CompletionCounter.stop(counter)
    end
  end

  @tag :load
  test "roots_only treats undefined parent_process_instance_id as root" do
    counter = CompletionCounter.start(roots_only: true)

    try do
      emit_state_change(%{parent_process_instance_id: :undefined})
      emit_state_change(%{parent_process_instance_id: @child_parent_id})

      assert CompletionCounter.count(counter) == 1
    after
      CompletionCounter.stop(counter)
    end
  end
end
