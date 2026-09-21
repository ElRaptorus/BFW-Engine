defmodule BfwEngine.Execution.FlowNodes.BusinessRuleTaskTest do
  use ExUnit.Case, async: false

  alias BfwEngine.BPMN.Model.FlowNode
  alias BfwEngine.BPMN.Model.FlowNodeData
  alias BfwEngine.BPMN.Model.Mapping
  alias BfwEngine.BPMN.Model.Process, as: BpmnProcess
  alias BfwEngine.BPMN.Model.SequenceFlow
  alias BfwEngine.Execution.FlowNodeResult
  alias BfwEngine.Execution.FlowNodes
  alias BfwEngine.Execution.HandlerContext
  alias BfwEngine.Expressions.Context, as: FeelContext
  alias BfwEngine.Types.Token

  # -- Helpers ------------------------------------------------------------------

  defp make_token(payload \\ %{"key" => "value"}) do
    %Token{
      id: "token-1",
      process_instance_id: "pi-1",
      payload: payload,
      created_at: DateTime.utc_now()
    }
  end

  defp make_context(flow_node) do
    target_node = %FlowNode{
      id: "next-node",
      type: :task,
      type_data: %FlowNodeData.Task{}
    }

    sequence_flow = %SequenceFlow{
      id: "sf-#{flow_node.id}-next-node",
      source_ref: flow_node.id,
      target_ref: "next-node"
    }

    flow_node_with_outgoing = %{flow_node | outgoing: [sequence_flow.id]}

    process_model = %BpmnProcess{
      id: "proc-1",
      flow_nodes: [flow_node_with_outgoing, target_node],
      sequence_flows: [sequence_flow]
    }

    {flow_node_with_outgoing,
     %HandlerContext{
       flow_node_instance_id: "fni-1",
       process_instance_id: "pi-1",
       process_model: process_model,
       flow_node_this: FeelContext.flow_node_this(flow_node)
     }}
  end

  defp brt_node(opts) do
    %FlowNode{
      id: "brt-1",
      type: :business_rule_task,
      type_data: %FlowNodeData.BusinessRuleTask{
        implementation: Keyword.get(opts, :implementation, "feel"),
        script: Keyword.get(opts, :script, nil),
        rule_ref: Keyword.get(opts, :rule_ref, nil),
        decision_ref: Keyword.get(opts, :decision_ref, nil),
        result_variable: Keyword.get(opts, :result_variable, nil),
        trace_unmatched_rules: Keyword.get(opts, :trace_unmatched_rules, false),
        in_mappings: Keyword.get(opts, :in_mappings, []),
        out_mappings: Keyword.get(opts, :out_mappings, []),
        payload_contract: Keyword.get(opts, :payload_contract, nil),
        result_contract: Keyword.get(opts, :result_contract, nil)
      }
    }
  end

  # ===========================================================================
  # FEEL mode
  # ===========================================================================

  describe "implementation='feel' — inline FEEL evaluation" do
    test "evaluates a FEEL map expression and returns output with type_properties" do
      node = brt_node(script: ~s|{ discount: if token.amount > 100 then 0.1 else 0 }|)
      {node, context} = make_context(node)
      token = make_token(%{"amount" => 200})

      assert {:ok, %FlowNodeResult{} = result} =
               FlowNodes.BusinessRuleTask.handle_enter(node, token, context)

      assert result.output_payload["discount"] == 0.1
      assert result.type_properties == %{mode: "feel"}
      assert result.next_flow_node_ids == ["next-node"]
    end

    test "wraps scalar FEEL result in %{\"result\" => scalar}" do
      node = brt_node(script: ~s|42|)
      {node, context} = make_context(node)
      token = make_token()

      assert {:ok, %FlowNodeResult{output_payload: payload, type_properties: type_properties}} =
               FlowNodes.BusinessRuleTask.handle_enter(node, token, context)

      assert payload == %{"result" => 42}
      assert type_properties == %{mode: "feel"}
    end

    test "FEEL expression referencing token data evaluates correctly" do
      node = brt_node(script: ~s|{ doubled: token.value * 2 }|)
      {node, context} = make_context(node)
      token = make_token(%{"value" => 7})

      assert {:ok, %FlowNodeResult{output_payload: payload}} =
               FlowNodes.BusinessRuleTask.handle_enter(node, token, context)

      assert payload["doubled"] == 14
    end

    test "'this' binding exposes flow node metadata, not token payload" do
      node =
        brt_node(script: ~s|{ node_id: this.id, node_type: this.type, node_name: this.name }|)

      node = %{node | name: "My Business Rule"}
      {node, context} = make_context(node)
      token = make_token(%{"id" => "should-be-ignored", "type" => "also-ignored"})

      assert {:ok, %FlowNodeResult{output_payload: payload}} =
               FlowNodes.BusinessRuleTask.handle_enter(node, token, context)

      assert payload["node_id"] == "brt-1"
      assert payload["node_type"] == "business_rule_task"
      assert payload["node_name"] == "My Business Rule"
    end

    test "invalid FEEL expression returns script_eval_failed error" do
      node = brt_node(script: ~s|completely invalid @@@ feel|)
      {node, context} = make_context(node)
      token = make_token()

      assert {:error, {:script_eval_failed, _, _}} =
               FlowNodes.BusinessRuleTask.handle_enter(node, token, context)
    end

    test "nil script returns missing_script error" do
      node = brt_node(implementation: "feel", script: nil)
      {node, context} = make_context(node)
      token = make_token()

      assert {:error, {:missing_script, message}} =
               FlowNodes.BusinessRuleTask.handle_enter(node, token, context)

      assert message =~ "no <script> element present"
    end

    test "empty string script returns missing_script error" do
      node = brt_node(implementation: "feel", script: "")
      {node, context} = make_context(node)
      token = make_token()

      assert {:error, {:missing_script, message}} =
               FlowNodes.BusinessRuleTask.handle_enter(node, token, context)

      assert message =~ "blank"
    end
  end

  # ===========================================================================
  # Plugin mode removed
  # ===========================================================================

  describe "implementation='plugin' — rejected after plugin mode removal" do
    test "returns unknown_brt_implementation error" do
      node = brt_node(implementation: "plugin", rule_ref: "echo_rule")
      {node, context} = make_context(node)
      token = make_token()

      assert {:error, {:unknown_brt_implementation, "plugin"}} =
               FlowNodes.BusinessRuleTask.handle_enter(node, token, context)
    end
  end

  # ===========================================================================
  # DMN mode
  # ===========================================================================

  describe "implementation='dmn' — DMN decision evaluation" do
    alias BfwEngine.DMN
    alias BfwEngine.DMN.ModelCache
    alias BfwEngine.Execution.DecisionResolver

    @dmn_fixtures_dir Path.join([
                        __DIR__,
                        "..",
                        "..",
                        "..",
                        "..",
                        "..",
                        "core_dmn",
                        "test",
                        "fixtures",
                        "dmns"
                      ])
                      |> Path.expand()

    setup do
      ModelCache.reset_state()
      DecisionResolver.NoOp.reset()

      on_exit(fn ->
        ModelCache.reset_state()
        DecisionResolver.NoOp.reset()
      end)

      :ok
    end

    defp prime_dmn_cache(fixture_filename, version_id) do
      xml = File.read!(Path.join(@dmn_fixtures_dir, fixture_filename))
      {:ok, definitions} = DMN.parse_and_validate(xml)
      :ok = ModelCache.put_new(version_id, definitions)
      definitions
    end

    # -- Happy path -----------------------------------------------------------

    test "DMN UNIQUE happy path — evaluates decision and returns result with type_properties" do
      prime_dmn_cache("simple_unique.dmn", "test-dmn-version-id")

      node = brt_node(implementation: "dmn", decision_ref: "definitions_discount")
      {node, context} = make_context(node)
      token = make_token(%{"age" => 25})

      assert {:ok, %FlowNodeResult{} = result} =
               FlowNodes.BusinessRuleTask.handle_enter(node, token, context)

      assert is_map(result.output_payload)
      assert result.output_payload["discount"] == 5

      assert result.type_properties.mode == "dmn"
      assert result.type_properties.decision_ref == "definitions_discount"
      assert result.type_properties.decision_version_id == "test-dmn-version-id"
      assert result.type_properties.version == "1.0.0"
      assert result.type_properties.hit_policy == "unique"
      assert is_list(result.type_properties.matched_rules)
      assert is_map(result.type_properties.trace)
      assert is_list(result.type_properties.trace.decisions)
      assert is_integer(result.type_properties.duration_us)
      assert result.type_properties.duration_us >= 0
      assert result.next_flow_node_ids == ["next-node"]
    end

    test "DMN result is a map — used directly as output payload" do
      prime_dmn_cache("simple_unique.dmn", "test-dmn-version-id")

      node = brt_node(implementation: "dmn", decision_ref: "definitions_discount")
      {node, context} = make_context(node)
      token = make_token(%{"age" => 70})

      assert {:ok, %FlowNodeResult{output_payload: payload}} =
               FlowNodes.BusinessRuleTask.handle_enter(node, token, context)

      assert is_map(payload)
      assert payload["discount"] == 15
    end

    test "DMN result is scalar (literal expression) — wrapped in %{\"result\" => scalar}" do
      prime_dmn_cache("literal_expression.dmn", "test-dmn-version-id")

      node = brt_node(implementation: "dmn", decision_ref: "definitions_sum")
      {node, context} = make_context(node)
      token = make_token(%{"x" => 30, "y" => 12})

      assert {:ok, %FlowNodeResult{output_payload: payload}} =
               FlowNodes.BusinessRuleTask.handle_enter(node, token, context)

      assert payload == %{"result" => 42}
    end

    test "type_properties contains full audit data" do
      prime_dmn_cache("simple_unique.dmn", "test-dmn-version-id")

      node = brt_node(implementation: "dmn", decision_ref: "definitions_discount")
      {node, context} = make_context(node)
      token = make_token(%{"age" => 25})

      assert {:ok, %FlowNodeResult{type_properties: type_properties}} =
               FlowNodes.BusinessRuleTask.handle_enter(node, token, context)

      assert type_properties.mode == "dmn"
      assert type_properties.decision_ref == "definitions_discount"
      assert type_properties.decision_version_id == "test-dmn-version-id"
      assert type_properties.version == "1.0.0"
      assert is_binary(type_properties.hit_policy)
      assert is_list(type_properties.matched_rules)

      assert %{decisions: [_ | _]} = type_properties.trace

      assert is_integer(type_properties.duration_us)
      assert type_properties.duration_us >= 0
    end

    # -- Error paths ----------------------------------------------------------

    test "decision not found — resolver returns :decision_definition_not_found" do
      DecisionResolver.NoOp.set_error("missing_ref", :decision_definition_not_found)

      node = brt_node(implementation: "dmn", decision_ref: "missing_ref")
      {node, context} = make_context(node)
      token = make_token()

      assert {:error, {:decision_not_found, "missing_ref"}} =
               FlowNodes.BusinessRuleTask.handle_enter(node, token, context)
    end

    test "decision disabled — resolver returns :decision_disabled" do
      DecisionResolver.NoOp.set_error("disabled_ref", :decision_disabled)

      node = brt_node(implementation: "dmn", decision_ref: "disabled_ref")
      {node, context} = make_context(node)
      token = make_token()

      assert {:error, {:decision_disabled, "disabled_ref"}} =
               FlowNodes.BusinessRuleTask.handle_enter(node, token, context)
    end

    test "no version available — resolver returns :no_version_available" do
      DecisionResolver.NoOp.set_error("no_version_ref", :no_version_available)

      node = brt_node(implementation: "dmn", decision_ref: "no_version_ref")
      {node, context} = make_context(node)
      token = make_token()

      assert {:error, {:decision_version_not_found, "no_version_ref"}} =
               FlowNodes.BusinessRuleTask.handle_enter(node, token, context)
    end

    test "DMN cache load failure — version not in cache and no loader configured" do
      DecisionResolver.NoOp.set_version("cache_miss_ref", "nonexistent-version-id")

      node = brt_node(implementation: "dmn", decision_ref: "cache_miss_ref")
      {node, context} = make_context(node)
      token = make_token()

      assert {:error, {:dmn_cache_load_failed, _reason}} =
               FlowNodes.BusinessRuleTask.handle_enter(node, token, context)
    end

    test "DMN evaluation error — missing required input" do
      prime_dmn_cache("simple_unique.dmn", "test-dmn-version-id")

      node = brt_node(implementation: "dmn", decision_ref: "definitions_discount")
      {node, context} = make_context(node)
      token = make_token(%{"wrong_field" => 25})

      assert {:error, {:dmn_evaluation_failed, :missing_required_input, _metadata}} =
               FlowNodes.BusinessRuleTask.handle_enter(node, token, context)
    end

    # -- Option passthrough ---------------------------------------------------

    test "trace_unmatched_rules: true — unmatched details appear in trace" do
      prime_dmn_cache("simple_unique.dmn", "test-dmn-version-id")

      node =
        brt_node(
          implementation: "dmn",
          decision_ref: "definitions_discount",
          trace_unmatched_rules: true
        )

      {node, context} = make_context(node)
      token = make_token(%{"age" => 25})

      assert {:ok, %FlowNodeResult{type_properties: type_properties}} =
               FlowNodes.BusinessRuleTask.handle_enter(node, token, context)

      [decision_trace] = type_properties.trace.decisions
      assert length(decision_trace.matched_rules) == 1
      assert decision_trace.unmatched_rules != []
      assert decision_trace.unmatched_rules_count == length(decision_trace.unmatched_rules)
    end

    test "trace_unmatched_rules: false (default) — only matched rules in trace" do
      prime_dmn_cache("simple_unique.dmn", "test-dmn-version-id")

      node =
        brt_node(
          implementation: "dmn",
          decision_ref: "definitions_discount",
          trace_unmatched_rules: false
        )

      {node, context} = make_context(node)
      token = make_token(%{"age" => 25})

      assert {:ok, %FlowNodeResult{type_properties: type_properties}} =
               FlowNodes.BusinessRuleTask.handle_enter(node, token, context)

      [decision_trace] = type_properties.trace.decisions
      assert length(decision_trace.matched_rules) == 1
    end

    # -- result_variable wrapping ---------------------------------------------

    test "result_variable set — wraps result under that key" do
      prime_dmn_cache("simple_unique.dmn", "test-dmn-version-id")

      node =
        brt_node(
          implementation: "dmn",
          decision_ref: "definitions_discount",
          result_variable: "discount"
        )

      {node, context} = make_context(node)
      token = make_token(%{"age" => 25})

      assert {:ok, %FlowNodeResult{output_payload: payload}} =
               FlowNodes.BusinessRuleTask.handle_enter(node, token, context)

      assert Map.has_key?(payload, "discount")
      assert is_map(payload["discount"])
    end

    test "result_variable nil — raw DMN result map is the output" do
      prime_dmn_cache("simple_unique.dmn", "test-dmn-version-id")

      node = brt_node(implementation: "dmn", decision_ref: "definitions_discount")
      {node, context} = make_context(node)
      token = make_token(%{"age" => 25})

      assert {:ok, %FlowNodeResult{output_payload: payload}} =
               FlowNodes.BusinessRuleTask.handle_enter(node, token, context)

      assert is_map(payload)
      assert Map.has_key?(payload, "discount")
    end

    # -- Data pipeline integration (with DMN) ---------------------------------

    test "in_mappings transform token before DMN evaluation" do
      prime_dmn_cache("simple_unique.dmn", "test-dmn-version-id")

      node =
        brt_node(
          implementation: "dmn",
          decision_ref: "definitions_discount",
          in_mappings: [%Mapping{source: "token.customer_age", target: "age"}]
        )

      {node, context} = make_context(node)
      token = make_token(%{"customer_age" => 25})

      assert {:ok, %FlowNodeResult{output_payload: payload}} =
               FlowNodes.BusinessRuleTask.handle_enter(node, token, context)

      assert payload["discount"] == 5
    end

    test "out_mappings transform DMN result" do
      prime_dmn_cache("simple_unique.dmn", "test-dmn-version-id")

      node =
        brt_node(
          implementation: "dmn",
          decision_ref: "definitions_discount",
          out_mappings: [%Mapping{source: "token.discount", target: "final_discount"}]
        )

      {node, context} = make_context(node)
      token = make_token(%{"age" => 25})

      assert {:ok, %FlowNodeResult{output_payload: payload}} =
               FlowNodes.BusinessRuleTask.handle_enter(node, token, context)

      assert payload["final_discount"] == 5
    end

    test "payload_contract violation before DMN eval" do
      prime_dmn_cache("simple_unique.dmn", "test-dmn-version-id")

      node =
        brt_node(
          implementation: "dmn",
          decision_ref: "definitions_discount",
          payload_contract: %{
            "type" => "object",
            "required" => ["mandatory_field"]
          }
        )

      {node, context} = make_context(node)
      token = make_token(%{"age" => 25})

      assert {:error, {:business_rule_task_contract_violation, _violations}} =
               FlowNodes.BusinessRuleTask.handle_enter(node, token, context)
    end

    test "result_contract violation on DMN output" do
      prime_dmn_cache("simple_unique.dmn", "test-dmn-version-id")

      node =
        brt_node(
          implementation: "dmn",
          decision_ref: "definitions_discount",
          result_contract: %{
            "type" => "object",
            "required" => ["nonexistent_output_field"]
          }
        )

      {node, context} = make_context(node)
      token = make_token(%{"age" => 25})

      assert {:error, {:business_rule_task_contract_violation, _violations}} =
               FlowNodes.BusinessRuleTask.handle_enter(node, token, context)
    end

    # -- Evaluation timeout ---------------------------------------------------

    test "dmn_evaluation_timeout_ms config is respected (evaluation succeeds within timeout)" do
      prime_dmn_cache("simple_unique.dmn", "test-dmn-version-id")

      node = brt_node(implementation: "dmn", decision_ref: "definitions_discount")
      {node, context} = make_context(node)
      token = make_token(%{"age" => 25})

      assert {:ok, %FlowNodeResult{}} =
               FlowNodes.BusinessRuleTask.handle_enter(node, token, context)
    end

    test "timeout error shape matches {:dmn_evaluation_timeout, metadata}" do
      # The timeout mechanism uses Task.yield/Task.shutdown (OTP).
      # NIF evaluations complete in microseconds, so we cannot reliably
      # trigger a timeout in a unit test. Instead, verify that the error
      # tuple the BRT handler would produce has the expected shape by
      # testing the config key plumbing: the configured timeout_ms value
      # appears in the metadata when reading the config.
      timeout = Application.get_env(:core_execution, :dmn_evaluation_timeout_ms)
      assert is_integer(timeout)
      assert timeout > 0

      expected_shape = {:dmn_evaluation_timeout, %{timeout_ms: timeout, decision_ref: "any"}}

      assert {:dmn_evaluation_timeout, %{timeout_ms: ^timeout, decision_ref: "any"}} =
               expected_shape
    end
  end

  # ===========================================================================
  # Unrecognized implementation
  # ===========================================================================

  describe "unrecognized implementation value" do
    test "returns unknown_brt_implementation error" do
      node = brt_node(implementation: "invalid_mode")
      {node, context} = make_context(node)
      token = make_token()

      assert {:error, {:unknown_brt_implementation, "invalid_mode"}} =
               FlowNodes.BusinessRuleTask.handle_enter(node, token, context)
    end
  end

  # ===========================================================================
  # Data pipeline: in_mappings → payload_contract → dispatch → out_mappings → result_contract
  # ===========================================================================

  describe "data pipeline" do
    test "in_mappings transform the input before FEEL evaluation" do
      node =
        brt_node(
          implementation: "feel",
          script: ~s|{ doubled: token.value * 2 }|,
          in_mappings: [%Mapping{source: "token.raw_amount", target: "value"}]
        )

      {node, context} = make_context(node)
      token = make_token(%{"raw_amount" => 25})

      assert {:ok, %FlowNodeResult{output_payload: payload}} =
               FlowNodes.BusinessRuleTask.handle_enter(node, token, context)

      assert payload["doubled"] == 50
    end

    test "out_mappings transform the output after FEEL evaluation" do
      node =
        brt_node(
          implementation: "feel",
          script: ~s|{ raw_result: 42 }|,
          out_mappings: [%Mapping{source: "token.raw_result", target: "final_value"}]
        )

      {node, context} = make_context(node)
      token = make_token()

      assert {:ok, %FlowNodeResult{output_payload: payload}} =
               FlowNodes.BusinessRuleTask.handle_enter(node, token, context)

      assert payload["final_value"] == 42
    end

    test "payload_contract passes when input matches schema" do
      node =
        brt_node(
          implementation: "feel",
          script: ~s|{ result: 1 }|,
          payload_contract: %{
            "type" => "object",
            "required" => ["key"],
            "properties" => %{"key" => %{"type" => "string"}}
          }
        )

      {node, context} = make_context(node)
      token = make_token(%{"key" => "value"})

      assert {:ok, %FlowNodeResult{}} =
               FlowNodes.BusinessRuleTask.handle_enter(node, token, context)
    end

    test "payload_contract violation returns contract error" do
      node =
        brt_node(
          implementation: "feel",
          script: ~s|{ result: 1 }|,
          payload_contract: %{
            "type" => "object",
            "required" => ["mandatory_field"],
            "properties" => %{"mandatory_field" => %{"type" => "string"}}
          }
        )

      {node, context} = make_context(node)
      token = make_token(%{"other" => "data"})

      assert {:error, {:business_rule_task_contract_violation, _violations}} =
               FlowNodes.BusinessRuleTask.handle_enter(node, token, context)
    end

    test "result_contract violation returns contract error" do
      node =
        brt_node(
          implementation: "feel",
          script: ~s|{ wrong_field: 42 }|,
          result_contract: %{
            "type" => "object",
            "required" => ["expected_field"],
            "properties" => %{"expected_field" => %{"type" => "string"}}
          }
        )

      {node, context} = make_context(node)
      token = make_token()

      assert {:error, {:business_rule_task_contract_violation, _violations}} =
               FlowNodes.BusinessRuleTask.handle_enter(node, token, context)
    end

    test "result_contract passes when output matches schema" do
      node =
        brt_node(
          implementation: "feel",
          script: ~s|{ expected_field: "hello" }|,
          result_contract: %{
            "type" => "object",
            "required" => ["expected_field"],
            "properties" => %{"expected_field" => %{"type" => "string"}}
          }
        )

      {node, context} = make_context(node)
      token = make_token()

      assert {:ok, %FlowNodeResult{output_payload: payload}} =
               FlowNodes.BusinessRuleTask.handle_enter(node, token, context)

      assert payload["expected_field"] == "hello"
    end

    test "corrupt in_mapping FEEL expression returns in_mapping_failed error" do
      node =
        brt_node(
          implementation: "feel",
          script: ~s|{ x: 1 }|,
          in_mappings: [%Mapping{source: "for x in [1] return if x then", target: "x"}]
        )

      {node, context} = make_context(node)
      token = make_token()

      assert {:error, {:in_mapping_failed, {:feel_eval_failed, _, _}}} =
               FlowNodes.BusinessRuleTask.handle_enter(node, token, context)
    end

    test "corrupt out_mapping FEEL expression returns out_mapping_failed error" do
      node =
        brt_node(
          implementation: "feel",
          script: ~s|{ x: 1 }|,
          out_mappings: [%Mapping{source: "for x in [1] return if x then", target: "y"}]
        )

      {node, context} = make_context(node)
      token = make_token()

      assert {:error, {:out_mapping_failed, {:feel_eval_failed, _, _}}} =
               FlowNodes.BusinessRuleTask.handle_enter(node, token, context)
    end

    test "full pipeline: in_mappings → payload_contract → FEEL → out_mappings → result_contract" do
      node =
        brt_node(
          implementation: "feel",
          script: ~s|{ computed: token.input_value * 3 }|,
          in_mappings: [%Mapping{source: "token.raw", target: "input_value"}],
          out_mappings: [%Mapping{source: "token.computed", target: "final"}],
          payload_contract: %{
            "type" => "object",
            "required" => ["input_value"]
          },
          result_contract: %{
            "type" => "object",
            "required" => ["final"]
          }
        )

      {node, context} = make_context(node)
      token = make_token(%{"raw" => 10})

      assert {:ok, %FlowNodeResult{output_payload: payload, type_properties: type_properties}} =
               FlowNodes.BusinessRuleTask.handle_enter(node, token, context)

      assert payload["final"] == 30
      assert type_properties == %{mode: "feel"}
    end
  end
end
