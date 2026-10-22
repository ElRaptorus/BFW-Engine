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

  describe "live_error_info/1" do
    test "reads the raised code and message from the persisted detail" do
      persisted = %{
        "error_code" => "BOOM",
        "message" => "Boom happened",
        "detail" => %{"error_code" => "BOOM", "error_message" => "Boom happened"}
      }

      assert ChildLifecycle.live_error_info(persisted) ==
               %{error_code: "BOOM", error_message: "Boom happened"}
    end

    test "keeps a nil raised code instead of the bpmn_error default" do
      persisted = %{
        "error_code" => "bpmn_error",
        "message" => "Process ended via Error End Event",
        "detail" => %{"error_code" => nil, "error_message" => nil}
      }

      assert ChildLifecycle.live_error_info(persisted) == %{error_code: nil, error_message: nil}
    end

    test "falls back to the top-level keys without a detail, and passes live maps through" do
      assert ChildLifecycle.live_error_info(%{"error_code" => "X", "message" => "m"}) ==
               %{error_code: "X", error_message: "m"}

      assert ChildLifecycle.live_error_info(%{error_code: "Y", error_message: "n"}) ==
               %{error_code: "Y", error_message: "n"}

      assert ChildLifecycle.live_error_info(nil) == %{error_code: nil, error_message: nil}
    end
  end

  describe "subprocess_model_id/2" do
    alias BfwEngine.BPMN.Model.FlowNode
    alias BfwEngine.BPMN.Model.Process, as: BpmnProcess
    alias BfwEngine.Execution.HandlerContext

    defp context_for(process_model_id),
      do: %HandlerContext{process_model: %BpmnProcess{id: process_model_id}}

    defp subprocess_node(id), do: %FlowNode{id: id, type: :sub_process, type_data: nil}

    test "a top-level subprocess is named after the process and the node" do
      assert ChildLifecycle.subprocess_model_id(context_for("order"), subprocess_node("Outer")) ==
               "order__subprocess__Outer"
    end

    test "a subprocess nested in a subprocess keeps only the top-level process id" do
      assert ChildLifecycle.subprocess_model_id(
               context_for("order__subprocess__Outer"),
               subprocess_node("Inner")
             ) == "order__subprocess__Inner"
    end

    test "three levels deep still yields a single suffix" do
      assert ChildLifecycle.subprocess_model_id(
               context_for("order__subprocess__Inner"),
               subprocess_node("Innermost")
             ) == "order__subprocess__Innermost"
    end
  end
end
