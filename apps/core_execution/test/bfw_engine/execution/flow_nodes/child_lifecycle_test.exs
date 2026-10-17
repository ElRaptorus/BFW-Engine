defmodule BfwEngine.Execution.FlowNodes.ChildLifecycleTest do
  use ExUnit.Case, async: true

  alias BfwEngine.Execution.FlowNodes.ChildLifecycle

  describe "await_child_completion/7 with an extra message handler" do
    test "leaves messages from other processes in the mailbox and handles only its child's cancel" do
      child_pid = spawn(fn -> receive do: (:stop -> :ok) end)
      reference = Process.monitor(child_pid)
      other_child_pid = spawn(fn -> :ok end)

      cancel_handler = fn
        {:child_pi_cancelled, _cancelled_pid, final_tokens} ->
          {:handled, {:cancelled, final_tokens}}

        _other ->
          :skip
      end

      send(self(), {:unrelated, :message})
      send(self(), {:child_pi_cancelled, other_child_pid, [:stale]})
      send(self(), {:child_pi_finished, child_pid, [:done]})

      assert {:finished, [:done]} =
               ChildLifecycle.await_child_completion(
                 child_pid,
                 reference,
                 "child-process-instance",
                 nil,
                 nil,
                 self(),
                 cancel_handler
               )

      assert_received {:unrelated, :message}
      assert_received {:child_pi_cancelled, ^other_child_pid, [:stale]}
      send(child_pid, :stop)
    end

    test "its child's cancel is passed to the handler" do
      child_pid = spawn(fn -> receive do: (:stop -> :ok) end)
      reference = Process.monitor(child_pid)

      cancel_handler = fn
        {:child_pi_cancelled, _cancelled_pid, final_tokens} ->
          {:handled, {:cancelled, final_tokens}}

        _other ->
          :skip
      end

      send(self(), {:child_pi_cancelled, child_pid, [:cancel_token]})

      assert {:cancelled, [:cancel_token]} =
               ChildLifecycle.await_child_completion(
                 child_pid,
                 reference,
                 "child-process-instance",
                 nil,
                 nil,
                 self(),
                 cancel_handler
               )

      send(child_pid, :stop)
    end
  end
end
