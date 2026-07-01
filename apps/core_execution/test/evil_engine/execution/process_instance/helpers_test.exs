defmodule EvilEngine.Execution.ProcessInstance.HelpersTest do
  use ExUnit.Case, async: true

  alias EvilEngine.Execution.ProcessInstance.Helpers

  describe "build_error_info humanization" do
    test "in_mapping_failed with FEEL detail" do
      result =
        Helpers.build_error_info(
          {:in_mapping_failed, {:feel_eval_failed, "token.x", "unknown variable"}}
        )

      assert result["message"] =~ "Input mapping failed"
      assert result["message"] =~ "token.x"
      assert result["error_code"] == "in_mapping_failed"
    end

    test "out_mapping_failed with FEEL detail" do
      result =
        Helpers.build_error_info(
          {:out_mapping_failed, {:feel_eval_failed, "result.y", "type error"}}
        )

      assert result["message"] =~ "Output mapping failed"
      assert result["message"] =~ "result.y"
    end

    test "no_handler_for_implementation" do
      result = Helpers.build_error_info({:no_handler_for_implementation, "custom_handler"})

      assert result["message"] =~ "custom_handler"
      assert result["message"] =~ "No handler registered"
    end

    test "missing_implementation with task ID" do
      result = Helpers.build_error_info({:missing_implementation, "Task_charge"})

      assert result["message"] =~ "Task_charge"
      assert result["message"] =~ "no implementation"
    end

    test "decision_not_found" do
      result = Helpers.build_error_info({:decision_not_found, "discount-rules"})

      assert result["message"] =~ "discount-rules"
      assert result["message"] =~ "not deployed"
    end

    test "payload_too_large" do
      result = Helpers.build_error_info({:payload_too_large, %{size: 5000, limit: 1000}})

      assert result["message"] =~ "5000"
      assert result["message"] =~ "1000"
    end

    test "crash" do
      result = Helpers.build_error_info({:crash, %RuntimeError{message: "boom"}})

      assert result["error_code"] == "crash"
      assert result["message"] =~ "crashed"
    end

    test "bare atom" do
      result = Helpers.build_error_info(:some_error)

      assert result["error_code"] == "some_error"
      assert result["message"] =~ "Some error"
    end

    test "unmapped atom tuple" do
      result = Helpers.build_error_info({:weird_error, "details"})

      assert result["message"] =~ "Weird error"
      assert result["message"] =~ "details"
    end

    test "string error" do
      result = Helpers.build_error_info("Something went wrong")

      assert result["message"] == "Something went wrong"
    end

    test "catch-all does not expose inspect" do
      result = Helpers.build_error_info([1, 2, 3])

      assert result["message"] == "An unexpected error occurred"
      refute result["message"] =~ "["
    end

    test "feel_eval_failed includes expression and reason" do
      result =
        Helpers.build_error_info({:feel_eval_failed, "bad expr (", "parse error"})

      assert result["error_code"] == "feel_eval_failed"
      assert result["message"] =~ "bad expr ("
      assert result["message"] =~ "parse error"
      refute result["message"] =~ "%{"
    end

    test "map with error_code atom key and error_message" do
      result = Helpers.build_error_info(%{error_code: "CUSTOM", error_message: "Something"})
      assert result["error_code"] == "CUSTOM"
      assert result["message"] == "Something"
    end

    test "map with string keys" do
      result = Helpers.build_error_info(%{"error_code" => "STR_CODE", "error_message" => "Msg"})
      assert result["error_code"] == "STR_CODE"
      assert result["message"] == "Msg"
    end

    test "generic map with :reason key" do
      result = Helpers.build_error_info(%{reason: "something happened"})
      assert result["message"] == "something happened"
      assert result["error_code"] == "error"
    end

    test "generic map with \"message\" key" do
      result = Helpers.build_error_info(%{"message" => "human message"})
      assert result["message"] == "human message"
    end

    test "generic map with no known keys" do
      result = Helpers.build_error_info(%{foo: "bar"})
      assert result["error_code"] == "error"
      assert result["message"] == "error"
      assert is_map(result["detail"])
    end

    test "decision_disabled" do
      result = Helpers.build_error_info({:decision_disabled, "my-rules"})
      assert result["message"] =~ "disabled"
      assert result["message"] =~ "my-rules"
    end

    test "dmn_evaluation_failed" do
      result = Helpers.build_error_info({:dmn_evaluation_failed, :cycle, %{}})
      assert result["message"] =~ "DMN evaluation failed"
      assert result["message"] =~ "cycle"
    end

    test "dmn_evaluation_timeout with timeout_ms" do
      result = Helpers.build_error_info({:dmn_evaluation_timeout, %{timeout_ms: 5000}})
      assert result["message"] =~ "5000"
    end

    test "dmn_evaluation_timeout without timeout_ms" do
      result = Helpers.build_error_info({:dmn_evaluation_timeout, %{}})
      assert result["message"] =~ "timed out"
    end

    test "payload_too_large without detail map" do
      result = Helpers.build_error_info({:payload_too_large, %{}})
      assert result["message"] =~ "limit"
    end

    test "called_element_resolution_failed with string detail" do
      result = Helpers.build_error_info({:called_element_resolution_failed, "not found"})
      assert result["message"] =~ "not found"
      assert result["message"] =~ "Call Activity"
    end

    test "called_element_resolution_failed with atom detail" do
      result = Helpers.build_error_info({:called_element_resolution_failed, :not_deployed})
      assert result["message"] =~ "Call Activity"
    end

    test "unknown_brt_implementation" do
      result = Helpers.build_error_info({:unknown_brt_implementation, "custom"})
      assert result["message"] =~ "custom"
      assert result["message"] =~ "feel"
    end

    test "start_event_not_found" do
      result = Helpers.build_error_info({:start_event_not_found, "Start_Express"})
      assert result["message"] =~ "Start_Express"
    end

    test "ambiguous_start_event" do
      result = Helpers.build_error_info({:ambiguous_start_event, %{}})
      assert result["message"] =~ "startEventId"
    end

    test "invalid_handler_return" do
      result = Helpers.build_error_info({:invalid_handler_return, %{}})
      assert result["message"] =~ "invalid result"
    end

    test "persistence_failed" do
      result = Helpers.build_error_info({:persistence_failed, %{}})
      assert result["message"] =~ "persist"
    end

    test "no_matching_condition with message" do
      result =
        Helpers.build_error_info(
          {:no_matching_condition, %{message: "No matching gateway branch"}}
        )

      assert result["message"] == "No matching gateway branch"
    end

    test "dead_end with message" do
      result = Helpers.build_error_info({:dead_end, %{message: "Dead end at Task_1"}})
      assert result["message"] == "Dead end at Task_1"
    end

    test "implicit_split with message" do
      result = Helpers.build_error_info({:implicit_split, %{message: "Implicit split at GW"}})
      assert result["message"] == "Implicit split at GW"
    end

    test "missing_script passes through string" do
      result = Helpers.build_error_info({:missing_script, "Script body is empty"})
      assert result["message"] == "Script body is empty"
    end

    test "no_handler_for_script_ref" do
      result = Helpers.build_error_info({:no_handler_for_script_ref, "my_script"})
      assert result["message"] =~ "my_script"
    end

    test "named_script_failed" do
      result = Helpers.build_error_info({:named_script_failed, "ref", :timeout})
      assert result["message"] =~ "ref"
    end

    test "script_eval_failed" do
      result = Helpers.build_error_info({:script_eval_failed, "x + ", "syntax error"})
      assert result["message"] =~ "syntax error"
    end

    test "service_task_contract_violation" do
      result =
        Helpers.build_error_info({:service_task_contract_violation, [%{message: "required"}]})

      assert result["message"] =~ "required"
    end

    test "user_task_input_contract_violation" do
      result =
        Helpers.build_error_info({:user_task_input_contract_violation, [%{message: "invalid"}]})

      assert result["message"] =~ "invalid"
    end

    test "contract_violation" do
      result = Helpers.build_error_info({:contract_violation, [%{message: "mismatch"}]})
      assert result["message"] =~ "mismatch"
    end

    test "in_mapping_failed with plain string detail" do
      result = Helpers.build_error_info({:in_mapping_failed, "mapping detail"})
      assert result["message"] =~ "Input mapping failed"
      assert result["message"] =~ "mapping detail"
    end

    test "out_mapping_failed with plain string detail" do
      result = Helpers.build_error_info({:out_mapping_failed, "output detail"})
      assert result["message"] =~ "Output mapping failed"
      assert result["message"] =~ "output detail"
    end

    test "unmapped atom tuple with non-string detail" do
      result = Helpers.build_error_info({:some_code, %{info: "data"}})
      assert result["error_code"] == "some_code"
      assert is_binary(result["message"])
    end

    test "in_mapping_failed with tuple detail" do
      result = Helpers.build_error_info({:in_mapping_failed, {:some_type, "detail_val"}})
      assert result["message"] =~ "Input mapping failed"
    end

    test "contract_violation with string-keyed violations" do
      violations = [%{"message" => "field X is required"}]
      result = Helpers.build_error_info({:service_task_contract_violation, violations})
      assert result["message"] =~ "field X is required"
    end

    test "contract_violation with tuple violations" do
      violations = [{"$.amount", "must be positive"}]
      result = Helpers.build_error_info({:service_task_contract_violation, violations})
      assert result["message"] =~ "$.amount"
      assert result["message"] =~ "must be positive"
    end

    test "contract_violation with bare string violations" do
      violations = ["Missing required field"]
      result = Helpers.build_error_info({:service_task_contract_violation, violations})
      assert result["message"] =~ "Missing required field"
    end

    test "contract_violation with non-standard violation shapes" do
      violations = [42]
      result = Helpers.build_error_info({:service_task_contract_violation, violations})
      assert is_binary(result["message"])
    end

    test "contract_violation with more than 3 violations truncates" do
      violations = Enum.map(1..6, fn i -> %{message: "violation #{i}"} end)
      result = Helpers.build_error_info({:service_task_contract_violation, violations})
      assert result["message"] =~ "and 3 more"
    end

    test "contract_violation with non-list violations" do
      result = Helpers.build_error_info({:service_task_contract_violation, "not a list"})
      assert result["message"] =~ "contract violation"
    end

    test "called_element_resolution_failed with map detail containing :message" do
      result =
        Helpers.build_error_info(
          {:called_element_resolution_failed, %{message: "version not found"}}
        )

      assert result["message"] =~ "version not found"
    end

    test "called_element_resolution_failed with map detail containing \"message\"" do
      result =
        Helpers.build_error_info(
          {:called_element_resolution_failed, %{"message" => "no such process"}}
        )

      assert result["message"] =~ "no such process"
    end

    test "called_element_resolution_failed with FEEL detail" do
      result =
        Helpers.build_error_info(
          {:called_element_resolution_failed, {:feel_eval_failed, "expr", "error"}}
        )

      assert result["message"] =~ "FEEL"
      assert result["message"] =~ "expr"
    end

    test "called_element_resolution_failed with opaque detail" do
      result = Helpers.build_error_info({:called_element_resolution_failed, 12_345})
      assert result["message"] =~ "see error details"
    end
  end

  describe "sanitize_error_info/1" do
    test "nil passes through" do
      assert Helpers.sanitize_error_info(nil) == nil
    end

    test "clean message passes through unchanged" do
      info = %{"error_code" => "test", "message" => "Something human-readable"}
      assert Helpers.sanitize_error_info(info) == info
    end

    test "message with %{ is sanitized" do
      info = %{"error_code" => "crash", "message" => "%{foo: bar}"}
      result = Helpers.sanitize_error_info(info)
      assert result["message"] =~ "An error occurred"
      assert result["message"] =~ "crash"
      refute result["message"] =~ "%{"
    end

    test "message with #PID< is sanitized" do
      info = %{"error_code" => "error", "message" => "Process #PID<0.123.0> crashed"}
      result = Helpers.sanitize_error_info(info)
      assert result["message"] =~ "An error occurred"
      refute result["message"] =~ "#PID<"
    end

    test "message with Elixir. module reference is sanitized" do
      info = %{
        "error_code" => "error",
        "message" => "Elixir.MyModule.function/2 is undefined"
      }

      result = Helpers.sanitize_error_info(info)
      assert result["message"] =~ "An error occurred"
    end

    test "message with ** (double-star exception marker) is sanitized" do
      info = %{"error_code" => "error", "message" => "** (RuntimeError) oops"}
      result = Helpers.sanitize_error_info(info)
      assert result["message"] =~ "An error occurred"
    end

    test "message with 'no function clause' is sanitized" do
      info = %{
        "error_code" => "error",
        "message" => "no function clause matching in SomeModule.fun/1"
      }

      result = Helpers.sanitize_error_info(info)
      assert result["message"] =~ "An error occurred"
    end

    test "message with FunctionClauseError is sanitized" do
      info = %{
        "error_code" => "error",
        "message" => "FunctionClauseError with args [1, 2]"
      }

      result = Helpers.sanitize_error_info(info)
      assert result["message"] =~ "An error occurred"
    end

    test "message with ArgumentError is sanitized" do
      info = %{
        "error_code" => "error",
        "message" => "ArgumentError: invalid argument"
      }

      result = Helpers.sanitize_error_info(info)
      assert result["message"] =~ "An error occurred"
    end

    test "defaults error_code to 'error' when missing" do
      info = %{"message" => "#PID<0.1.0> died"}
      result = Helpers.sanitize_error_info(info)
      assert result["message"] =~ "error code: error"
    end

    test "non-map value passes through" do
      assert Helpers.sanitize_error_info("just a string") == "just a string"
    end

    test "map without message key passes through" do
      info = %{"error_code" => "test"}
      assert Helpers.sanitize_error_info(info) == info
    end

    test "preserves other fields in error_info" do
      info = %{
        "error_code" => "crash",
        "message" => "%{bad: stuff}",
        "detail" => %{"extra" => true}
      }

      result = Helpers.sanitize_error_info(info)
      assert result["detail"] == %{"extra" => true}
      assert result["error_code"] == "crash"
    end
  end

  describe "looks_like_elixir_internal?/1" do
    test "returns true for %{ pattern" do
      assert Helpers.looks_like_elixir_internal?("%{foo: bar}")
    end

    test "returns true for #PID< pattern" do
      assert Helpers.looks_like_elixir_internal?("Process #PID<0.1.0>")
    end

    test "returns true for Elixir. pattern" do
      assert Helpers.looks_like_elixir_internal?("Elixir.Module")
    end

    test "returns true for ** pattern" do
      assert Helpers.looks_like_elixir_internal?("** (RuntimeError)")
    end

    test "returns true for 'no function clause'" do
      assert Helpers.looks_like_elixir_internal?("no function clause matching")
    end

    test "returns true for FunctionClauseError" do
      assert Helpers.looks_like_elixir_internal?("FunctionClauseError in fun/1")
    end

    test "returns true for ArgumentError" do
      assert Helpers.looks_like_elixir_internal?("ArgumentError: bad")
    end

    test "returns false for clean human message" do
      refute Helpers.looks_like_elixir_internal?("Service task 'Task_1' has no implementation")
    end

    test "returns false for non-string" do
      refute Helpers.looks_like_elixir_internal?(42)
    end

    test "returns false for nil" do
      refute Helpers.looks_like_elixir_internal?(nil)
    end
  end

  describe "to_json_safe/1" do
    test "nil" do
      assert Helpers.to_json_safe(nil) == nil
    end

    test "string" do
      assert Helpers.to_json_safe("hello") == "hello"
    end

    test "integer" do
      assert Helpers.to_json_safe(42) == 42
    end

    test "float" do
      assert Helpers.to_json_safe(3.14) == 3.14
    end

    test "boolean" do
      assert Helpers.to_json_safe(true) == true
      assert Helpers.to_json_safe(false) == false
    end

    test "atom" do
      assert Helpers.to_json_safe(:hello) == "hello"
    end

    test "tuple" do
      assert Helpers.to_json_safe({:a, "b"}) == ["a", "b"]
    end

    test "list" do
      assert Helpers.to_json_safe([:a, 1, "c"]) == ["a", 1, "c"]
    end

    test "struct is converted to map without __meta__" do
      struct = %RuntimeError{message: "oops"}
      result = Helpers.to_json_safe(struct)
      assert is_map(result)
      assert result["message"] == "oops"
      refute Map.has_key?(result, "__meta__")
    end

    test "map with atom keys" do
      result = Helpers.to_json_safe(%{a: 1, b: "two"})
      assert result == %{"a" => 1, "b" => "two"}
    end

    test "map with string keys" do
      result = Helpers.to_json_safe(%{"x" => :y})
      assert result == %{"x" => "y"}
    end

    test "map with integer keys" do
      result = Helpers.to_json_safe(%{1 => "one"})
      assert result == %{"1" => "one"}
    end

    test "nested structures" do
      result = Helpers.to_json_safe(%{nested: %{a: [:x, :y]}})
      assert result == %{"nested" => %{"a" => ["x", "y"]}}
    end

    test "non-serializable value falls back to inspect" do
      pid = self()
      result = Helpers.to_json_safe(pid)
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
        result = Helpers.build_error_info(unquote(Macro.escape(error_shape)))

        assert result["message"] =~ unquote(expected_context),
               "Expected message to contain '#{unquote(expected_context)}', got: #{result["message"]}"
      end
    end
  end

  describe "stringify_keys/1" do
    test "nil" do
      assert Helpers.stringify_keys(nil) == nil
    end

    test "atom keys" do
      assert Helpers.stringify_keys(%{foo: 1}) == %{"foo" => 1}
    end

    test "string keys pass through" do
      assert Helpers.stringify_keys(%{"bar" => 2}) == %{"bar" => 2}
    end

    test "mixed keys" do
      input = Map.merge(%{atom_key: 1}, %{"string_key" => 2})
      assert Helpers.stringify_keys(input) == %{"atom_key" => 1, "string_key" => 2}
    end
  end
end
