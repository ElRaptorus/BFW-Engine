defmodule EvilEngine.Execution.EscalationResolverTest do
  use ExUnit.Case, async: true

  alias EvilEngine.BPMN.Model.Definitions
  alias EvilEngine.BPMN.Model.EscalationDefinition
  alias EvilEngine.BPMN.Model.EventDefinition
  alias EvilEngine.BPMN.Model.FlowNode
  alias EvilEngine.BPMN.Model.FlowNodeData
  alias EvilEngine.BPMN.Model.Process, as: BpmnProcess
  alias EvilEngine.Execution.EscalationResolver

  defp build_definitions(escalations \\ []) do
    %Definitions{
      definitions_id: "Definitions_1",
      escalations: escalations,
      raw_xml: ""
    }
  end

  defp build_host_and_model(boundary_nodes) do
    host = %FlowNode{
      id: "SP_1",
      type: :sub_process,
      type_data: %FlowNodeData.SubProcess{},
      incoming: ["Flow_1"],
      outgoing: ["Flow_2"],
      boundary_event_refs: Enum.map(boundary_nodes, & &1.id)
    }

    model = %BpmnProcess{
      id: "proc",
      flow_nodes: [host | boundary_nodes]
    }

    {host, model}
  end

  defp escalation_boundary(id, opts \\ []) do
    escalation_ref = Keyword.get(opts, :escalation_ref)
    escalation_code = Keyword.get(opts, :escalation_code)
    cancel_activity = Keyword.get(opts, :cancel_activity, true)

    %FlowNode{
      id: id,
      type: :boundary_event,
      type_data: %FlowNodeData.BoundaryEvent{
        attached_to_ref: "SP_1",
        cancel_activity: cancel_activity,
        event_definition: %EventDefinition.Escalation{
          escalation_ref: escalation_ref,
          escalation_code: escalation_code
        }
      }
    }
  end

  # ---------------------------------------------------------------------------
  # resolve_escalation_info/2
  # ---------------------------------------------------------------------------

  describe "resolve_escalation_info/2" do
    test "returns nil code and name when escalation_ref is nil" do
      event_def = %EventDefinition.Escalation{escalation_ref: nil}
      definitions = build_definitions()

      assert %{escalation_code: nil, escalation_name: nil} ==
               EscalationResolver.resolve_escalation_info(event_def, definitions)
    end

    test "resolves code and name from global EscalationDefinition" do
      escalation = %EscalationDefinition{
        id: "Esc_Payment",
        name: "Payment Escalation",
        escalation_code: "ESC_PAYMENT"
      }

      event_def = %EventDefinition.Escalation{escalation_ref: "Esc_Payment"}
      definitions = build_definitions([escalation])

      assert %{escalation_code: "ESC_PAYMENT", escalation_name: "Payment Escalation"} ==
               EscalationResolver.resolve_escalation_info(event_def, definitions)
    end

    test "returns nil code when referenced global definition has no escalation_code" do
      escalation = %EscalationDefinition{
        id: "Esc_1",
        name: "Unnamed",
        escalation_code: nil
      }

      event_def = %EventDefinition.Escalation{escalation_ref: "Esc_1"}
      definitions = build_definitions([escalation])

      assert %{escalation_code: nil, escalation_name: "Unnamed"} ==
               EscalationResolver.resolve_escalation_info(event_def, definitions)
    end

    test "returns nil when escalation_ref points to non-existent global definition" do
      event_def = %EventDefinition.Escalation{escalation_ref: "Esc_NonExistent"}
      definitions = build_definitions([])

      assert %{escalation_code: nil, escalation_name: nil} ==
               EscalationResolver.resolve_escalation_info(event_def, definitions)
    end
  end

  # ---------------------------------------------------------------------------
  # find_first_interrupting_escalation_boundary/4
  # ---------------------------------------------------------------------------

  describe "find_first_interrupting_escalation_boundary/4" do
    test "returns :none when host has no boundary events" do
      {host, model} = build_host_and_model([])
      definitions = build_definitions()

      assert :none ==
               EscalationResolver.find_first_interrupting_escalation_boundary(
                 host,
                 model,
                 definitions,
                 %{escalation_code: "ESC_A"}
               )
    end

    test "matches by exact escalation code" do
      escalation_def = %EscalationDefinition{
        id: "Esc_A",
        name: "A",
        escalation_code: "ESC_A"
      }

      boundary = escalation_boundary("BE_1", escalation_ref: "Esc_A")
      {host, model} = build_host_and_model([boundary])
      definitions = build_definitions([escalation_def])

      assert {:ok, matched} =
               EscalationResolver.find_first_interrupting_escalation_boundary(
                 host,
                 model,
                 definitions,
                 %{escalation_code: "ESC_A"}
               )

      assert matched.id == "BE_1"
    end

    test "does not match when escalation code differs" do
      escalation_def = %EscalationDefinition{id: "Esc_A", escalation_code: "ESC_A"}
      boundary = escalation_boundary("BE_1", escalation_ref: "Esc_A")
      {host, model} = build_host_and_model([boundary])
      definitions = build_definitions([escalation_def])

      assert :none ==
               EscalationResolver.find_first_interrupting_escalation_boundary(
                 host,
                 model,
                 definitions,
                 %{escalation_code: "ESC_B"}
               )
    end

    test "catch-all boundary (nil escalation_ref) matches any code" do
      boundary = escalation_boundary("BE_catch_all")
      {host, model} = build_host_and_model([boundary])
      definitions = build_definitions()

      assert {:ok, matched} =
               EscalationResolver.find_first_interrupting_escalation_boundary(
                 host,
                 model,
                 definitions,
                 %{escalation_code: "ANYTHING"}
               )

      assert matched.id == "BE_catch_all"
    end

    test "matches inline escalation_code without a global ref" do
      boundary = escalation_boundary("BE_inline", escalation_code: "ESC_INLINE")
      {host, model} = build_host_and_model([boundary])
      definitions = build_definitions()

      assert {:ok, matched} =
               EscalationResolver.find_first_interrupting_escalation_boundary(
                 host,
                 model,
                 definitions,
                 %{escalation_code: "ESC_INLINE"}
               )

      assert matched.id == "BE_inline"
    end

    test "inline escalation_code does not match a different raised code" do
      boundary = escalation_boundary("BE_inline", escalation_code: "ESC_INLINE")
      {host, model} = build_host_and_model([boundary])
      definitions = build_definitions()

      assert :none ==
               EscalationResolver.find_first_interrupting_escalation_boundary(
                 host,
                 model,
                 definitions,
                 %{escalation_code: "ESC_OTHER"}
               )
    end

    test "catch-all boundary matches when raised escalation has nil code" do
      boundary = escalation_boundary("BE_catch_all")
      {host, model} = build_host_and_model([boundary])
      definitions = build_definitions()

      assert {:ok, _matched} =
               EscalationResolver.find_first_interrupting_escalation_boundary(
                 host,
                 model,
                 definitions,
                 %{escalation_code: nil}
               )
    end

    test "returns first matching boundary when multiple exist" do
      esc_a = %EscalationDefinition{id: "Esc_A", escalation_code: "ESC_A"}
      b1 = escalation_boundary("BE_1", escalation_ref: "Esc_A")
      b2 = escalation_boundary("BE_2")
      {host, model} = build_host_and_model([b1, b2])
      definitions = build_definitions([esc_a])

      assert {:ok, matched} =
               EscalationResolver.find_first_interrupting_escalation_boundary(
                 host,
                 model,
                 definitions,
                 %{escalation_code: "ESC_A"}
               )

      assert matched.id == "BE_1"
    end

    test "falls through to catch-all when specific boundary does not match" do
      esc_a = %EscalationDefinition{id: "Esc_A", escalation_code: "ESC_A"}
      b_specific = escalation_boundary("BE_specific", escalation_ref: "Esc_A")
      b_catch_all = escalation_boundary("BE_catch_all")
      {host, model} = build_host_and_model([b_specific, b_catch_all])
      definitions = build_definitions([esc_a])

      assert {:ok, matched} =
               EscalationResolver.find_first_interrupting_escalation_boundary(
                 host,
                 model,
                 definitions,
                 %{escalation_code: "ESC_OTHER"}
               )

      assert matched.id == "BE_catch_all"
    end

    test "ignores non-interrupting boundaries" do
      escalation_def = %EscalationDefinition{id: "Esc_A", escalation_code: "ESC_A"}

      non_interrupting =
        escalation_boundary("BE_non", escalation_ref: "Esc_A", cancel_activity: false)

      {host, model} = build_host_and_model([non_interrupting])
      definitions = build_definitions([escalation_def])

      assert :none ==
               EscalationResolver.find_first_interrupting_escalation_boundary(
                 host,
                 model,
                 definitions,
                 %{escalation_code: "ESC_A"}
               )
    end

    test "ignores non-escalation boundaries" do
      timer_boundary = %FlowNode{
        id: "BE_timer",
        type: :boundary_event,
        type_data: %FlowNodeData.BoundaryEvent{
          attached_to_ref: "SP_1",
          cancel_activity: true,
          event_definition: %EventDefinition.Timer{}
        }
      }

      {host, model} = build_host_and_model([timer_boundary])
      definitions = build_definitions()

      assert :none ==
               EscalationResolver.find_first_interrupting_escalation_boundary(
                 host,
                 model,
                 definitions,
                 %{escalation_code: "ESC_A"}
               )
    end
  end

  # ---------------------------------------------------------------------------
  # find_non_interrupting_escalation_boundaries/4
  # ---------------------------------------------------------------------------

  describe "find_non_interrupting_escalation_boundaries/4" do
    test "returns empty list when host has no boundary events" do
      {host, model} = build_host_and_model([])
      definitions = build_definitions()

      assert [] ==
               EscalationResolver.find_non_interrupting_escalation_boundaries(
                 host,
                 model,
                 definitions,
                 %{escalation_code: "ESC_A"}
               )
    end

    test "returns matching non-interrupting boundaries" do
      esc_a = %EscalationDefinition{id: "Esc_A", escalation_code: "ESC_A"}
      b_non_int = escalation_boundary("BE_non", escalation_ref: "Esc_A", cancel_activity: false)
      {host, model} = build_host_and_model([b_non_int])
      definitions = build_definitions([esc_a])

      result =
        EscalationResolver.find_non_interrupting_escalation_boundaries(
          host,
          model,
          definitions,
          %{escalation_code: "ESC_A"}
        )

      assert length(result) == 1
      assert hd(result).id == "BE_non"
    end

    test "returns all matching non-interrupting boundaries (parallel trigger)" do
      esc_a = %EscalationDefinition{id: "Esc_A", escalation_code: "ESC_A"}
      b1 = escalation_boundary("BE_1", escalation_ref: "Esc_A", cancel_activity: false)
      b2 = escalation_boundary("BE_2", cancel_activity: false)
      {host, model} = build_host_and_model([b1, b2])
      definitions = build_definitions([esc_a])

      result =
        EscalationResolver.find_non_interrupting_escalation_boundaries(
          host,
          model,
          definitions,
          %{escalation_code: "ESC_A"}
        )

      assert length(result) == 2
    end

    test "ignores interrupting boundaries" do
      esc_a = %EscalationDefinition{id: "Esc_A", escalation_code: "ESC_A"}
      interrupting = escalation_boundary("BE_int", escalation_ref: "Esc_A", cancel_activity: true)
      {host, model} = build_host_and_model([interrupting])
      definitions = build_definitions([esc_a])

      assert [] ==
               EscalationResolver.find_non_interrupting_escalation_boundaries(
                 host,
                 model,
                 definitions,
                 %{escalation_code: "ESC_A"}
               )
    end
  end
end
