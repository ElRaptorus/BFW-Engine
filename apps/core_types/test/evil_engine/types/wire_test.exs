defmodule EvilEngine.Types.WireTest do
  use ExUnit.Case, async: true

  alias EvilEngine.Types.Wire

  describe "camelize_key/1" do
    test "converts snake_case atom to camelCase string" do
      assert Wire.camelize_key(:process_instance_id) == "processInstanceId"
    end

    test "converts snake_case string to camelCase string" do
      assert Wire.camelize_key("process_instance_id") == "processInstanceId"
    end

    test "single-word atom passes through" do
      assert Wire.camelize_key(:state) == "state"
    end

    test "single-word string passes through" do
      assert Wire.camelize_key("state") == "state"
    end

    test "already camelCase string passes through" do
      assert Wire.camelize_key("processModelId") == "processModelId"
    end

    test "empty string passes through" do
      assert Wire.camelize_key("") == ""
    end

    test "multiple underscores produce correct camelCase" do
      assert Wire.camelize_key(:started_with_context) == "startedWithContext"
    end
  end

  describe "camelize_keys/1" do
    test "converts atom-keyed map" do
      input = %{process_model_id: "order", latest_version: "1.0.0", state: "active"}

      result = Wire.camelize_keys(input)

      assert result == %{
               "processModelId" => "order",
               "latestVersion" => "1.0.0",
               "state" => "active"
             }
    end

    test "converts string-keyed map" do
      input = %{"process_model_id" => "order", "latest_version" => "1.0.0"}

      result = Wire.camelize_keys(input)

      assert result == %{"processModelId" => "order", "latestVersion" => "1.0.0"}
    end

    test "recurses into nested maps" do
      input = %{
        process_model_id: "order",
        inner_map: %{nested_key: "value", deeper: %{deep_key: 42}}
      }

      result = Wire.camelize_keys(input)

      assert result == %{
               "processModelId" => "order",
               "innerMap" => %{
                 "nestedKey" => "value",
                 "deeper" => %{"deepKey" => 42}
               }
             }
    end

    test "recurses into lists of maps" do
      input = %{items: [%{item_name: "a"}, %{item_name: "b"}]}

      result = Wire.camelize_keys(input)

      assert result == %{"items" => [%{"itemName" => "a"}, %{"itemName" => "b"}]}
    end

    test "handles empty map" do
      assert Wire.camelize_keys(%{}) == %{}
    end

    test "passes through nil" do
      assert Wire.camelize_keys(nil) == nil
    end

    test "passes through scalar values" do
      assert Wire.camelize_keys(42) == 42
      assert Wire.camelize_keys("hello") == "hello"
      assert Wire.camelize_keys(true) == true
    end

    test "handles empty list" do
      assert Wire.camelize_keys([]) == []
    end

    test "handles list of scalars" do
      assert Wire.camelize_keys([1, 2, 3]) == [1, 2, 3]
    end

    test "handles mixed nil values in map" do
      input = %{process_model_id: nil, state: "running"}

      result = Wire.camelize_keys(input)

      assert result == %{"processModelId" => nil, "state" => "running"}
    end
  end

  describe "opaque field boundary" do
    test ":payload value is not recursed into" do
      input = %{
        process_instance_id: "pi-1",
        payload: %{"snake_nested_key" => "user_value", "deep" => %{"another_key" => 1}}
      }

      result = Wire.camelize_keys(input)

      assert result["processInstanceId"] == "pi-1"

      assert result["payload"] == %{
               "snake_nested_key" => "user_value",
               "deep" => %{"another_key" => 1}
             }
    end

    test ":claims value is not recursed into" do
      input = %{id: "user-1", claims: %{"custom_claim" => true, "org_id" => "org-42"}}

      result = Wire.camelize_keys(input)

      assert result["id"] == "user-1"
      assert result["claims"] == %{"custom_claim" => true, "org_id" => "org-42"}
    end

    test ":result value is not recursed into" do
      input = %{flow_node_id: "task-1", result: %{"order_total" => 99.99}}

      result = Wire.camelize_keys(input)

      assert result["flowNodeId"] == "task-1"
      assert result["result"] == %{"order_total" => 99.99}
    end

    test ":input_token value is not recursed into" do
      input = %{state: "running", input_token: %{"user_data" => "preserved"}}

      result = Wire.camelize_keys(input)

      assert result["inputToken"] == %{"user_data" => "preserved"}
    end

    test ":violations value is not recursed into" do
      input = %{
        error: "contract_violation",
        violations: [%{"path" => "$.amount", "message" => "required"}]
      }

      result = Wire.camelize_keys(input)

      assert result["violations"] == [%{"path" => "$.amount", "message" => "required"}]
    end

    test ":metadata value is not recursed into" do
      input = %{event_type: "custom", metadata: %{"trace_id" => "abc", "custom_tag" => "x"}}

      result = Wire.camelize_keys(input)

      assert result["eventType"] == "custom"
      assert result["metadata"] == %{"trace_id" => "abc", "custom_tag" => "x"}
    end

    test ":type_properties value is not recursed into" do
      input = %{
        flow_node_instance_id: "fni-1",
        type_properties: %{"hit_policy" => "UNIQUE", "nested_trace" => %{"rule_index" => 1}}
      }

      result = Wire.camelize_keys(input)

      assert result["flowNodeInstanceId"] == "fni-1"

      assert result["typeProperties"] == %{
               "hit_policy" => "UNIQUE",
               "nested_trace" => %{"rule_index" => 1}
             }
    end

    test ":error_info value is not recursed into" do
      input = %{
        terminal_state: "fatal",
        error_info: %{
          "error_code" => "in_mapping_failed",
          "detail" => %{"expression" => "token.x"}
        }
      }

      result = Wire.camelize_keys(input)

      assert result["terminalState"] == "fatal"

      assert result["errorInfo"] == %{
               "error_code" => "in_mapping_failed",
               "detail" => %{"expression" => "token.x"}
             }
    end

    test ":started_with_context value is not recursed into" do
      input = %{
        process_instance_id: "pi-1",
        started_with_context: %{"tenant_id" => "acme", "nested" => %{"lane_key" => "value"}}
      }

      result = Wire.camelize_keys(input)

      assert result["processInstanceId"] == "pi-1"

      assert result["startedWithContext"] == %{
               "tenant_id" => "acme",
               "nested" => %{"lane_key" => "value"}
             }
    end

    test ":form_fields value is not recursed into" do
      input = %{
        flow_node_id: "task-1",
        form_fields: %{"fields" => [%{"field_name" => "approved", "field_type" => "boolean"}]}
      }

      result = Wire.camelize_keys(input)

      assert result["flowNodeId"] == "task-1"

      assert result["formFields"] == %{
               "fields" => [%{"field_name" => "approved", "field_type" => "boolean"}]
             }
    end

    test "string opaque keys also skip recursion" do
      input = %{"process_model_id" => "order", "payload" => %{"inner_key" => "preserved"}}

      result = Wire.camelize_keys(input)

      assert result["processModelId"] == "order"
      assert result["payload"] == %{"inner_key" => "preserved"}
    end

    test "engine-structural fields like failures ARE recursed into" do
      input = %{
        error: "validation_failed",
        failures: [%{file: "process.bpmn", ruleset_failures: ["rule-1"]}]
      }

      result = Wire.camelize_keys(input)

      assert result["error"] == "validation_failed"
      [failure] = result["failures"]
      assert failure["file"] == "process.bpmn"
      assert failure["rulesetFailures"] == ["rule-1"]
    end

    test "engine-structural field conflicts IS recursed into" do
      input = %{
        error: "version_exists",
        conflicts: [%{process_model_id: "order", version: "1.0.0"}]
      }

      result = Wire.camelize_keys(input)

      [conflict] = result["conflicts"]
      assert conflict["processModelId"] == "order"
      assert conflict["version"] == "1.0.0"
    end
  end

  describe "struct_to_camel_map/1" do
    test "converts a Token struct" do
      token = %EvilEngine.Types.Token{
        id: "tok-1",
        process_instance_id: "pi-1",
        originating_flow_node_instance_id: "fni-1",
        payload: %{"user_key" => "preserved"}
      }

      result = Wire.struct_to_camel_map(token)

      assert result["id"] == "tok-1"
      assert result["processInstanceId"] == "pi-1"
      assert result["originatingFlowNodeInstanceId"] == "fni-1"
      assert result["payload"] == %{"user_key" => "preserved"}
      refute Map.has_key?(result, :__struct__)
    end

    test "converts an Identity struct" do
      identity = %EvilEngine.Types.Identity{
        id: "user-1",
        roles: ["admin"],
        groups: ["engineering"],
        claims: %{"custom_claim" => "not_touched"}
      }

      result = Wire.struct_to_camel_map(identity)

      assert result["id"] == "user-1"
      assert result["roles"] == ["admin"]
      assert result["groups"] == ["engineering"]
      assert result["claims"] == %{"custom_claim" => "not_touched"}
    end

    test "converts a FinalToken struct" do
      final = %EvilEngine.Types.FinalToken{
        end_event_id: "end-1",
        end_event_name: "Success",
        payload: %{"final_data" => true}
      }

      result = Wire.struct_to_camel_map(final)

      assert result["endEventId"] == "end-1"
      assert result["endEventName"] == "Success"
      assert result["payload"] == %{"final_data" => true}
    end
  end
end
