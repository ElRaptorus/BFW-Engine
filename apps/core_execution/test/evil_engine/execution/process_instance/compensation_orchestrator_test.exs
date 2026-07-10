defmodule EvilEngine.Execution.ProcessInstance.CompensationOrchestratorTest do
  use ExUnit.Case, async: true

  alias EvilEngine.Execution.ProcessInstance.CompensationOrchestrator

  defp build_target(id, completion_order) do
    %{
      completed_fni_id: "fni_#{id}",
      flow_node_id: "node_#{id}",
      handler_activity_id: "handler_#{id}",
      token_snapshot: %{"key" => "value_#{id}"},
      completion_order: completion_order
    }
  end

  defp build_run_with_targets(targets, opts \\ []) do
    throw_type = Keyword.get(opts, :throw_type, :throw)
    outgoing = Keyword.get(opts, :outgoing_flow_node_ids, ["Flow_out"])
    payload = Keyword.get(opts, :token_payload, %{"x" => 1})

    CompensationOrchestrator.build_run(targets, throw_type, outgoing, payload)
  end

  # ---------------------------------------------------------------------------
  # build_run/4
  # ---------------------------------------------------------------------------

  describe "build_run/4" do
    test "builds a broadcast run when targets has multiple entries" do
      targets = [build_target("a", 0), build_target("b", 1)]

      run = build_run_with_targets(targets)

      assert run.mode == :broadcast
    end

    test "builds a single run when targets has exactly one entry" do
      targets = [build_target("a", 0)]

      run = build_run_with_targets(targets)

      assert run.mode == :single
    end

    test "builds a broadcast run when targets is empty" do
      run = build_run_with_targets([])

      assert run.mode == :broadcast
    end

    test "preserves throw_type, outgoing_flow_node_ids, and token_payload" do
      targets = [build_target("a", 0)]
      outgoing = ["Flow_1", "Flow_2"]
      payload = %{"order" => "abc"}

      run =
        CompensationOrchestrator.build_run(targets, :end, outgoing, payload)

      assert run.throw_type == :end
      assert run.outgoing_flow_node_ids == ["Flow_1", "Flow_2"]
      assert run.token_payload == %{"order" => "abc"}
    end

    test "initializes cursor at 0" do
      run = build_run_with_targets([build_target("a", 0)])

      assert run.cursor == 0
    end
  end

  # ---------------------------------------------------------------------------
  # current_target/1
  # ---------------------------------------------------------------------------

  describe "current_target/1" do
    test "returns the first target when cursor is 0" do
      target_a = build_target("a", 0)
      target_b = build_target("b", 1)
      run = build_run_with_targets([target_a, target_b])

      assert CompensationOrchestrator.current_target(run) == target_a
    end

    test "returns the second target after one advance" do
      target_a = build_target("a", 0)
      target_b = build_target("b", 1)

      run =
        [target_a, target_b]
        |> build_run_with_targets()
        |> CompensationOrchestrator.advance_cursor()

      assert CompensationOrchestrator.current_target(run) == target_b
    end

    test "returns nil when cursor is past the end of the queue" do
      run =
        [build_target("a", 0)]
        |> build_run_with_targets()
        |> CompensationOrchestrator.advance_cursor()

      assert CompensationOrchestrator.current_target(run) == nil
    end

    test "returns nil for an empty queue" do
      run = build_run_with_targets([])

      assert CompensationOrchestrator.current_target(run) == nil
    end
  end

  # ---------------------------------------------------------------------------
  # advance_cursor/1
  # ---------------------------------------------------------------------------

  describe "advance_cursor/1" do
    test "increments cursor by one" do
      run = build_run_with_targets([build_target("a", 0), build_target("b", 1)])

      advanced = CompensationOrchestrator.advance_cursor(run)

      assert advanced.cursor == 1
    end

    test "can advance past the end of the queue" do
      run =
        [build_target("a", 0)]
        |> build_run_with_targets()
        |> CompensationOrchestrator.advance_cursor()
        |> CompensationOrchestrator.advance_cursor()

      assert run.cursor == 2
    end
  end

  # ---------------------------------------------------------------------------
  # run_complete?/1
  # ---------------------------------------------------------------------------

  describe "run_complete?/1" do
    test "returns false when cursor is before the end" do
      run = build_run_with_targets([build_target("a", 0), build_target("b", 1)])

      refute CompensationOrchestrator.run_complete?(run)
    end

    test "returns true when cursor equals the queue length" do
      run =
        [build_target("a", 0)]
        |> build_run_with_targets()
        |> CompensationOrchestrator.advance_cursor()

      assert CompensationOrchestrator.run_complete?(run)
    end

    test "returns true when cursor exceeds the queue length" do
      run =
        [build_target("a", 0)]
        |> build_run_with_targets()
        |> CompensationOrchestrator.advance_cursor()
        |> CompensationOrchestrator.advance_cursor()

      assert CompensationOrchestrator.run_complete?(run)
    end

    test "returns true for an empty queue with cursor 0" do
      run = build_run_with_targets([])

      assert CompensationOrchestrator.run_complete?(run)
    end
  end
end
