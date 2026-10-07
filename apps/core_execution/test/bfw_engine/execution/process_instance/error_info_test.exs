defmodule BfwEngine.Execution.ProcessInstance.ErrorInfoTest do
  use ExUnit.Case, async: true

  alias BfwEngine.Execution.ProcessInstance.ErrorInfo
  alias BfwEngine.Execution.ProcessInstance.JsonSafe

  describe "ErrorInfo.build/1 humanization" do
    test "in_mapping_failed with FEEL detail" do
      result =
        ErrorInfo.build({:in_mapping_failed, {:feel_eval_failed, "token.x", "unknown variable"}})

      assert result["message"] =~ "Input mapping failed"
      assert result["message"] =~ "token.x"
      assert result["error_code"] == "in_mapping_failed"
    end

    test "out_mapping_failed with FEEL detail" do
      result =
        ErrorInfo.build({:out_mapping_failed, {:feel_eval_failed, "result.y", "type error"}})

      assert result["message"] =~ "Output mapping failed"
      assert result["message"] =~ "result.y"
    end

    test "no_handler_for_implementation" do
      result = ErrorInfo.build({:no_handler_for_implementation, "custom_handler"})

      assert result["message"] =~ "custom_handler"
      assert result["message"] =~ "No handler registered"
    end

    test "missing_implementation with task ID" do
      result = ErrorInfo.build({:missing_implementation, "Task_charge"})

      assert result["message"] =~ "Task_charge"
      assert result["message"] =~ "no implementation"
    end

    test "decision_not_found" do
      result = ErrorInfo.build({:decision_not_found, "discount-rules"})

      assert result["message"] =~ "discount-rules"
      assert result["message"] =~ "not deployed"
    end

    test "payload_too_large" do
      result = ErrorInfo.build({:payload_too_large, %{size: 5000, limit: 1000}})

      assert result["message"] =~ "5000"
      assert result["message"] =~ "1000"
    end

    test "crash" do
      result = ErrorInfo.build({:crash, %RuntimeError{message: "boom"}})

      assert result["error_code"] == "crash"
      assert result["message"] =~ "crashed"
    end

    test "bare atom" do
      result = ErrorInfo.build(:some_error)

      assert result["error_code"] == "some_error"
      assert result["message"] =~ "Some error"
    end

    test "unmapped atom tuple" do
      result = ErrorInfo.build({:weird_error, "details"})

      assert result["message"] =~ "Weird error"
      assert result["message"] =~ "details"
    end

    test "string error" do
      result = ErrorInfo.build("Something went wrong")

      assert result["message"] == "Something went wrong"
    end

    test "catch-all does not expose inspect" do
      result = ErrorInfo.build([1, 2, 3])

      assert result["message"] == "An unexpected error occurred"
      refute result["message"] =~ "["
    end

    test "feel_eval_failed includes expression and reason" do
      result =
        ErrorInfo.build({:feel_eval_failed, "bad expr (", "parse error"})

      assert result["error_code"] == "feel_eval_failed"
      assert result["message"] =~ "bad expr ("
      assert result["message"] =~ "parse error"
      refute result["message"] =~ "%{"
    end

    test "map with error_code atom key and error_message" do
      result = ErrorInfo.build(%{error_code: "CUSTOM", error_message: "Something"})
      assert result["error_code"] == "CUSTOM"
      assert result["message"] == "Something"
    end

    test "map with string keys" do
      result = ErrorInfo.build(%{"error_code" => "STR_CODE", "error_message" => "Msg"})
      assert result["error_code"] == "STR_CODE"
      assert result["message"] == "Msg"
    end

    test "generic map with :reason key" do
      result = ErrorInfo.build(%{reason: "something happened"})
      assert result["message"] == "something happened"
      assert result["error_code"] == "error"
    end

    test "generic map with \"message\" key" do
      result = ErrorInfo.build(%{"message" => "human message"})
      assert result["message"] == "human message"
    end

    test "generic map with no known keys" do
      result = ErrorInfo.build(%{foo: "bar"})
      assert result["error_code"] == "error"
      assert result["message"] == "error"
      assert is_map(result["detail"])
    end

    test "decision_disabled" do
      result = ErrorInfo.build({:decision_disabled, "my-rules"})
      assert result["message"] =~ "disabled"
      assert result["message"] =~ "my-rules"
    end

    test "dmn_evaluation_failed" do
      result = ErrorInfo.build({:dmn_evaluation_failed, :cycle, %{}})
      assert result["message"] =~ "DMN evaluation failed"
      assert result["message"] =~ "cycle"
    end

    test "dmn_evaluation_timeout with timeout_ms" do
      result = ErrorInfo.build({:dmn_evaluation_timeout, %{timeout_ms: 5000}})
      assert result["message"] =~ "5000"
    end

    test "dmn_evaluation_timeout without timeout_ms" do
      result = ErrorInfo.build({:dmn_evaluation_timeout, %{}})
      assert result["message"] =~ "timed out"
    end

    test "payload_too_large without detail map" do
      result = ErrorInfo.build({:payload_too_large, %{}})
      assert result["message"] =~ "limit"
    end

    test "called_element_resolution_failed with string detail" do
      result = ErrorInfo.build({:called_element_resolution_failed, "not found"})
      assert result["message"] =~ "not found"
      assert result["message"] =~ "Call Activity"
    end

    test "called_element_resolution_failed with atom detail" do
      result = ErrorInfo.build({:called_element_resolution_failed, :not_deployed})
      assert result["message"] =~ "Call Activity"
    end

    test "called_process_version_not_found names process id and version" do
      result =
        ErrorInfo.build({:called_process_version_not_found, "order-fulfillment", "1.2.0"})

      assert result["message"] =~ "order-fulfillment"
      assert result["message"] =~ "1.2.0"
      assert result["message"] =~ "latest"
    end

    test "version_disabled names catalog disable" do
      result = ErrorInfo.build(:version_disabled)
      assert result["message"] =~ "disabled"
      assert result["message"] =~ "Call Activity"
    end

    test "unknown_brt_implementation" do
      result = ErrorInfo.build({:unknown_brt_implementation, "custom"})
      assert result["message"] =~ "custom"
      assert result["message"] =~ "feel"
    end

    test "start_event_not_found" do
      result = ErrorInfo.build({:start_event_not_found, "Start_Express"})
      assert result["message"] =~ "Start_Express"
    end

    test "ambiguous_start_event" do
      result = ErrorInfo.build({:ambiguous_start_event, %{}})
      assert result["message"] =~ "startEventId"
    end

    test "invalid_handler_return" do
      result = ErrorInfo.build({:invalid_handler_return, %{}})
      assert result["message"] =~ "invalid result"
    end

    test "persistence_failed" do
      result = ErrorInfo.build({:persistence_failed, %{}})
      assert result["message"] =~ "persist"
    end

    test "no_matching_condition with message" do
      result =
        ErrorInfo.build({:no_matching_condition, %{message: "No matching gateway branch"}})

      assert result["message"] == "No matching gateway branch"
    end

    test "dead_end with message" do
      result = ErrorInfo.build({:dead_end, %{message: "Dead end at Task_1"}})
      assert result["message"] == "Dead end at Task_1"
    end

    test "implicit_split with message" do
      result = ErrorInfo.build({:implicit_split, %{message: "Implicit split at GW"}})
      assert result["message"] == "Implicit split at GW"
    end

    test "missing_script passes through string" do
      result = ErrorInfo.build({:missing_script, "Script body is empty"})
      assert result["message"] == "Script body is empty"
    end

    test "no_handler_for_script_ref" do
      result = ErrorInfo.build({:no_handler_for_script_ref, "my_script"})
      assert result["message"] =~ "my_script"
    end

    test "named_script_failed" do
      result = ErrorInfo.build({:named_script_failed, "ref", :timeout})
      assert result["message"] =~ "ref"
    end

    test "script_eval_failed" do
      result = ErrorInfo.build({:script_eval_failed, "x + ", "syntax error"})
      assert result["message"] =~ "syntax error"
    end

    test "service_task_contract_violation" do
      result =
        ErrorInfo.build({:service_task_contract_violation, [%{message: "required"}]})

      assert result["message"] =~ "required"
    end

    test "user_task_input_contract_violation" do
      result =
        ErrorInfo.build({:user_task_input_contract_violation, [%{message: "invalid"}]})

      assert result["message"] =~ "invalid"
    end

    test "contract_violation" do
      result = ErrorInfo.build({:contract_violation, [%{message: "mismatch"}]})
      assert result["message"] =~ "mismatch"
    end

    test "in_mapping_failed with plain string detail" do
      result = ErrorInfo.build({:in_mapping_failed, "mapping detail"})
      assert result["message"] =~ "Input mapping failed"
      assert result["message"] =~ "mapping detail"
    end

    test "out_mapping_failed with plain string detail" do
      result = ErrorInfo.build({:out_mapping_failed, "output detail"})
      assert result["message"] =~ "Output mapping failed"
      assert result["message"] =~ "output detail"
    end

    test "unmapped atom tuple with non-string detail" do
      result = ErrorInfo.build({:some_code, %{info: "data"}})
      assert result["error_code"] == "some_code"
      assert is_binary(result["message"])
    end

    test "in_mapping_failed with tuple detail" do
      result = ErrorInfo.build({:in_mapping_failed, {:some_type, "detail_val"}})
      assert result["message"] =~ "Input mapping failed"
    end

    test "contract_violation with string-keyed violations" do
      violations = [%{"message" => "field X is required"}]
      result = ErrorInfo.build({:service_task_contract_violation, violations})
      assert result["message"] =~ "field X is required"
    end

    test "contract_violation with tuple violations" do
      violations = [{"$.amount", "must be positive"}]
      result = ErrorInfo.build({:service_task_contract_violation, violations})
      assert result["message"] =~ "$.amount"
      assert result["message"] =~ "must be positive"
    end

    test "contract_violation with bare string violations" do
      violations = ["Missing required field"]
      result = ErrorInfo.build({:service_task_contract_violation, violations})
      assert result["message"] =~ "Missing required field"
    end

    test "contract_violation with non-standard violation shapes" do
      violations = [42]
      result = ErrorInfo.build({:service_task_contract_violation, violations})
      assert is_binary(result["message"])
    end

    test "contract_violation with more than 3 violations truncates" do
      violations = Enum.map(1..6, fn i -> %{message: "violation #{i}"} end)
      result = ErrorInfo.build({:service_task_contract_violation, violations})
      assert result["message"] =~ "and 3 more"
    end

    test "contract_violation with non-list violations" do
      result = ErrorInfo.build({:service_task_contract_violation, "not a list"})
      assert result["message"] =~ "contract violation"
    end

    test "called_element_resolution_failed with map detail containing :message" do
      result =
        ErrorInfo.build({:called_element_resolution_failed, %{message: "version not found"}})

      assert result["message"] =~ "version not found"
    end

    test "called_element_resolution_failed with map detail containing \"message\"" do
      result =
        ErrorInfo.build({:called_element_resolution_failed, %{"message" => "no such process"}})

      assert result["message"] =~ "no such process"
    end

    test "called_element_resolution_failed with FEEL detail" do
      result =
        ErrorInfo.build({:called_element_resolution_failed, {:feel_eval_failed, "expr", "error"}})

      assert result["message"] =~ "FEEL"
      assert result["message"] =~ "expr"
    end

    test "called_element_resolution_failed with opaque detail" do
      result = ErrorInfo.build({:called_element_resolution_failed, 12_345})
      assert result["message"] =~ "see error details"
    end
  end

  describe "ErrorInfo.sanitize/1" do
    test "nil passes through" do
      assert ErrorInfo.sanitize(nil) == nil
    end

    test "clean message passes through unchanged" do
      info = %{"error_code" => "test", "message" => "Something human-readable"}
      assert ErrorInfo.sanitize(info) == info
    end

    test "message with %{ is sanitized" do
      info = %{"error_code" => "crash", "message" => "%{foo: bar}"}
      result = ErrorInfo.sanitize(info)
      assert result["message"] =~ "An error occurred"
      assert result["message"] =~ "crash"
      refute result["message"] =~ "%{"
    end

    test "message with #PID< is sanitized" do
      info = %{"error_code" => "error", "message" => "Process #PID<0.123.0> crashed"}
      result = ErrorInfo.sanitize(info)
      assert result["message"] =~ "An error occurred"
      refute result["message"] =~ "#PID<"
    end

    test "message with Elixir. module reference is sanitized" do
      info = %{
        "error_code" => "error",
        "message" => "Elixir.MyModule.function/2 is undefined"
      }

      result = ErrorInfo.sanitize(info)
      assert result["message"] =~ "An error occurred"
    end

    test "message with ** (double-star exception marker) is sanitized" do
      info = %{"error_code" => "error", "message" => "** (RuntimeError) oops"}
      result = ErrorInfo.sanitize(info)
      assert result["message"] =~ "An error occurred"
    end

    test "message with 'no function clause' is sanitized" do
      info = %{
        "error_code" => "error",
        "message" => "no function clause matching in SomeModule.fun/1"
      }

      result = ErrorInfo.sanitize(info)
      assert result["message"] =~ "An error occurred"
    end

    test "message with FunctionClauseError is sanitized" do
      info = %{
        "error_code" => "error",
        "message" => "FunctionClauseError with args [1, 2]"
      }

      result = ErrorInfo.sanitize(info)
      assert result["message"] =~ "An error occurred"
    end

    test "message with ArgumentError is sanitized" do
      info = %{
        "error_code" => "error",
        "message" => "ArgumentError: invalid argument"
      }

      result = ErrorInfo.sanitize(info)
      assert result["message"] =~ "An error occurred"
    end

    test "defaults error_code to 'error' when missing" do
      info = %{"message" => "#PID<0.1.0> died"}
      result = ErrorInfo.sanitize(info)
      assert result["message"] =~ "error code: error"
    end

    test "non-map value passes through" do
      assert ErrorInfo.sanitize("just a string") == "just a string"
    end

    test "ArgumentError text without an exception marker is sanitized" do
      info = %{"error_code" => "error", "message" => "ArgumentError raised"}
      result = ErrorInfo.sanitize(info)
      assert result["message"] =~ "An error occurred"
      refute result["message"] =~ "ArgumentError"
    end

    test "a non-binary message passes through" do
      info = %{"error_code" => "error", "message" => nil}
      assert ErrorInfo.sanitize(info) == info
    end

    test "map without message key passes through" do
      info = %{"error_code" => "test"}
      assert ErrorInfo.sanitize(info) == info
    end

    test "preserves other fields in error_info" do
      info = %{
        "error_code" => "crash",
        "message" => "%{bad: stuff}",
        "detail" => %{"extra" => true}
      }

      result = ErrorInfo.sanitize(info)
      assert result["detail"] == %{"extra" => true}
      assert result["error_code"] == "crash"
    end
  end

  describe "JsonSafe.convert/1" do
    test "nil" do
      assert JsonSafe.convert(nil) == nil
    end

    test "string" do
      assert JsonSafe.convert("hello") == "hello"
    end

    test "integer" do
      assert JsonSafe.convert(42) == 42
    end

    test "float" do
      assert JsonSafe.convert(3.14) == 3.14
    end

    test "boolean" do
      assert JsonSafe.convert(true) == true
      assert JsonSafe.convert(false) == false
    end

    test "atom" do
      assert JsonSafe.convert(:hello) == "hello"
    end

    test "tuple" do
      assert JsonSafe.convert({:a, "b"}) == ["a", "b"]
    end

    test "list" do
      assert JsonSafe.convert([:a, 1, "c"]) == ["a", 1, "c"]
    end

    test "struct is converted to map without __meta__" do
      struct = %RuntimeError{message: "oops"}
      result = JsonSafe.convert(struct)
      assert is_map(result)
      assert result["message"] == "oops"
      refute Map.has_key?(result, "__meta__")
    end

    test "map with atom keys" do
      result = JsonSafe.convert(%{a: 1, b: "two"})
      assert result == %{"a" => 1, "b" => "two"}
    end

    test "map with string keys" do
      result = JsonSafe.convert(%{"x" => :y})
      assert result == %{"x" => "y"}
    end

    test "map with integer keys" do
      result = JsonSafe.convert(%{1 => "one"})
      assert result == %{"1" => "one"}
    end

    test "nested structures" do
      result = JsonSafe.convert(%{nested: %{a: [:x, :y]}})
      assert result == %{"nested" => %{"a" => ["x", "y"]}}
    end

    test "non-serializable value falls back to inspect" do
      pid = self()
      result = JsonSafe.convert(pid)
      assert is_binary(result)
      assert result =~ "#PID<"
    end
  end

  describe "diagnostic quality gate" do
    @error_shapes [
      {{:in_mapping_failed, {:feel_eval_failed, "token.x", "reason"}}, "token.x"},
      {{:out_mapping_failed, {:feel_eval_failed, "result.y", "reason"}}, "result.y"},
      {{:feel_eval_failed, "bad expr (", "parse error"}, "bad expr ("},
      {{:no_handler_for_implementation, "http"}, "http"},
      {{:missing_implementation, "Task_1"}, "Task_1"},
      {{:decision_not_found, "my-decision"}, "my-decision"},
      {{:decision_disabled, "my-decision"}, "my-decision"},
      {{:payload_too_large, %{size: 1000, limit: 500}}, "1000"},
      {{:dmn_evaluation_timeout, %{timeout_ms: 3000}}, "3000"},
      {{:unknown_brt_implementation, "plugin"}, "plugin"},
      {{:start_event_not_found, "Start_X"}, "Start_X"},
      {{:no_handler_for_script_ref, "my_script"}, "my_script"},
      {{:named_script_failed, "my_script", :timeout}, "my_script"},
      {{:no_matching_condition, %{message: "No matching gateway branch"}},
       "No matching gateway branch"},
      {{:dead_end, %{message: "Dead end at Task_1"}}, "Dead end"},
      {{:implicit_split, %{message: "Implicit split at Gateway_1"}}, "Implicit split"},
      {{:missing_script, "Script body is empty"}, "Script body is empty"},
      {{:script_eval_failed, "x + ", "syntax error"}, "syntax error"},
      {{:dmn_evaluation_failed, :cycle, %{}}, "cycle"},
      {{:service_task_contract_violation, [%{message: "field required"}]}, "field required"},
      {{:user_task_input_contract_violation, [%{message: "invalid type"}]}, "invalid type"},
      {{:contract_violation, [%{message: "schema mismatch"}]}, "schema mismatch"},
      {{:called_element_resolution_failed, "child-not-found"}, "child-not-found"},
      {{:called_process_version_not_found, "order-fulfillment", "1.2.0"}, "order-fulfillment"},
      {:version_disabled, "disabled"},
      {{:in_mapping_failed, "mapping detail"}, "mapping detail"},
      {{:out_mapping_failed, "output detail"}, "output detail"},
      {{:ambiguous_start_event, %{}}, "startEventId"},
      {{:invalid_handler_return, %{}}, "invalid result"},
      {{:persistence_failed, %{}}, "persist"},
      {{:payload_too_large, %{}}, "limit"},
      {{:dmn_evaluation_timeout, %{}}, "timed out"}
    ]

    for {{error_shape, expected_context}, index} <- Enum.with_index(@error_shapes) do
      @tag :"quality_gate_#{index}"
      test "error shape #{inspect(error_shape)} includes context '#{expected_context}'" do
        result = ErrorInfo.build(unquote(Macro.escape(error_shape)))

        assert result["message"] =~ unquote(expected_context),
               "Expected message to contain '#{unquote(expected_context)}', got: #{result["message"]}"
      end
    end
  end

  describe "ad-hoc subprocess error humanization" do
    test "not_adhoc_subprocess" do
      result = ErrorInfo.build(:not_adhoc_subprocess)
      assert result["error_code"] == "not_adhoc_subprocess"
      assert result["message"] =~ "not an ad-hoc subprocess"
    end

    test "adhoc_activity_not_found" do
      result = ErrorInfo.build(:adhoc_activity_not_found)
      assert result["error_code"] == "adhoc_activity_not_found"
      assert result["message"] =~ "not found"
    end

    test "adhoc_already_completing" do
      result = ErrorInfo.build(:adhoc_already_completing)
      assert result["error_code"] == "adhoc_already_completing"
      assert result["message"] =~ "already been signaled"
    end

    test "dispatch_failed" do
      result = ErrorInfo.build(:dispatch_failed)
      assert result["error_code"] == "dispatch_failed"
      assert result["message"] =~ "dispatch"
    end

    test "adhoc_subprocess_empty" do
      result = ErrorInfo.build({:adhoc_subprocess_empty, "No inner activities"})
      assert result["error_code"] == "adhoc_subprocess_empty"
      assert result["message"] == "No inner activities"
    end

    test "retry_inside_adhoc_subprocess" do
      result = ErrorInfo.build(:retry_inside_adhoc_subprocess)
      assert result["error_code"] == "retry_inside_adhoc_subprocess"
      assert result["message"] =~ "ad-hoc subprocess"
    end
  end
end
