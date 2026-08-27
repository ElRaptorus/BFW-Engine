defmodule EvilEngine.Execution.CompensationResolverTest do
  use ExUnit.Case, async: true

  alias EvilEngine.BPMN.Model.EventDefinition
  alias EvilEngine.Execution.CompensationResolver

  defp build_registry_entry(opts) do
    %{
      completed_fni_id: Keyword.fetch!(opts, :completed_fni_id),
      flow_node_id: Keyword.fetch!(opts, :flow_node_id),
      handler_activity_id: Keyword.fetch!(opts, :handler_activity_id),
      token_snapshot: Keyword.get(opts, :token_snapshot, %{}),
      completion_order: Keyword.fetch!(opts, :completion_order)
    }
  end

  defp compensation_event_definition(activity_ref) do
    %EventDefinition.Compensation{activity_ref: activity_ref, wait_for_completion: true}
  end

  # ---------------------------------------------------------------------------
  # resolve/2 with activityRef (single target)
  # ---------------------------------------------------------------------------

  describe "resolve/2 with activityRef (single target)" do
    test "returns the single matching entry when activityRef matches a registry entry" do
      entry =
        build_registry_entry(
          completed_fni_id: "fni_1",
          flow_node_id: "Task_A",
          handler_activity_id: "Comp_A",
          completion_order: 0
        )

      result = CompensationResolver.resolve([entry], compensation_event_definition("Task_A"))

      assert length(result) == 1
      assert hd(result).flow_node_id == "Task_A"
    end

    test "returns empty list when activityRef does not match any registry entry" do
      entry =
        build_registry_entry(
          completed_fni_id: "fni_1",
          flow_node_id: "Task_A",
          handler_activity_id: "Comp_A",
          completion_order: 0
        )

      result = CompensationResolver.resolve([entry], compensation_event_definition("Task_B"))

      assert result == []
    end

    test "returns empty list when registry is empty and activityRef is set" do
      result = CompensationResolver.resolve([], compensation_event_definition("Task_A"))

      assert result == []
    end

    test "ignores other entries when activityRef matches one" do
      entry_a =
        build_registry_entry(
          completed_fni_id: "fni_1",
          flow_node_id: "Task_A",
          handler_activity_id: "Comp_A",
          completion_order: 0
        )

      entry_b =
        build_registry_entry(
          completed_fni_id: "fni_2",
          flow_node_id: "Task_B",
          handler_activity_id: "Comp_B",
          completion_order: 1
        )

      entry_c =
        build_registry_entry(
          completed_fni_id: "fni_3",
          flow_node_id: "Task_C",
          handler_activity_id: "Comp_C",
          completion_order: 2
        )

      result =
        CompensationResolver.resolve(
          [entry_a, entry_b, entry_c],
          compensation_event_definition("Task_B")
        )

      assert length(result) == 1
      assert hd(result).flow_node_id == "Task_B"
      assert hd(result).completed_fni_id == "fni_2"
    end
  end

  # ---------------------------------------------------------------------------
  # resolve/2 broadcast (no activityRef)
  # ---------------------------------------------------------------------------

  describe "resolve/2 broadcast (no activityRef)" do
    test "returns all entries in reverse completion order (LIFO)" do
      entry_0 =
        build_registry_entry(
          completed_fni_id: "fni_1",
          flow_node_id: "Task_A",
          handler_activity_id: "Comp_A",
          completion_order: 0
        )

      entry_1 =
        build_registry_entry(
          completed_fni_id: "fni_2",
          flow_node_id: "Task_B",
          handler_activity_id: "Comp_B",
          completion_order: 1
        )

      entry_2 =
        build_registry_entry(
          completed_fni_id: "fni_3",
          flow_node_id: "Task_C",
          handler_activity_id: "Comp_C",
          completion_order: 2
        )

      result =
        CompensationResolver.resolve(
          [entry_0, entry_1, entry_2],
          compensation_event_definition(nil)
        )

      assert length(result) == 3
      assert Enum.map(result, & &1.completion_order) == [2, 1, 0]
    end

    test "returns empty list when registry is empty" do
      result = CompensationResolver.resolve([], compensation_event_definition(nil))

      assert result == []
    end

    test "returns single entry when registry has one entry" do
      entry =
        build_registry_entry(
          completed_fni_id: "fni_1",
          flow_node_id: "Task_A",
          handler_activity_id: "Comp_A",
          completion_order: 0
        )

      result = CompensationResolver.resolve([entry], compensation_event_definition(nil))

      assert length(result) == 1
      assert hd(result).flow_node_id == "Task_A"
    end

    test "preserves all entry fields in the output" do
      token = %{"orderId" => "ORD-123", "amount" => 42}

      entry =
        build_registry_entry(
          completed_fni_id: "fni_99",
          flow_node_id: "Task_X",
          handler_activity_id: "Comp_X",
          token_snapshot: token,
          completion_order: 7
        )

      result = CompensationResolver.resolve([entry], compensation_event_definition(nil))

      returned = hd(result)
      assert returned.completed_fni_id == "fni_99"
      assert returned.flow_node_id == "Task_X"
      assert returned.handler_activity_id == "Comp_X"
      assert returned.token_snapshot == token
      assert returned.completion_order == 7
    end
  end

  # ---------------------------------------------------------------------------
  # resolve/2 edge cases
  # ---------------------------------------------------------------------------

  describe "resolve/2 edge cases" do
    test "treats empty-string activityRef as broadcast" do
      entry_0 =
        build_registry_entry(
          completed_fni_id: "fni_1",
          flow_node_id: "Task_A",
          handler_activity_id: "Comp_A",
          completion_order: 0
        )

      entry_1 =
        build_registry_entry(
          completed_fni_id: "fni_2",
          flow_node_id: "Task_B",
          handler_activity_id: "Comp_B",
          completion_order: 1
        )

      result =
        CompensationResolver.resolve(
          [entry_0, entry_1],
          compensation_event_definition("")
        )

      assert length(result) == 2
      assert Enum.map(result, & &1.completion_order) == [1, 0]
    end

    test "treats nil activityRef as broadcast" do
      entry_0 =
        build_registry_entry(
          completed_fni_id: "fni_1",
          flow_node_id: "Task_A",
          handler_activity_id: "Comp_A",
          completion_order: 0
        )

      entry_1 =
        build_registry_entry(
          completed_fni_id: "fni_2",
          flow_node_id: "Task_B",
          handler_activity_id: "Comp_B",
          completion_order: 1
        )

      result =
        CompensationResolver.resolve(
          [entry_0, entry_1],
          compensation_event_definition(nil)
        )

      assert length(result) == 2
      assert Enum.map(result, & &1.completion_order) == [1, 0]
    end
  end
end
