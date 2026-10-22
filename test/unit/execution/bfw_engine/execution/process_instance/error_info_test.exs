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

    test "map with an atom reason uses the reason as error_code and keeps its message" do
      result =
        ErrorInfo.build(%{
          reason: :no_matching_condition,
          flow_node_id: "XOR_1",
          message: "No outgoing sequence flow with a fulfilled condition"
        })

      assert result["error_code"] == "no_matching_condition"
      assert result["message"] == "No outgoing sequence flow with a fulfilled condition"
      assert result["detail"]["flow_node_id"] == "XOR_1"
    end

    test "map with an atom reason and no message is humanized" do
      result =
        ErrorInfo.build(%{
          reason: :no_matching_link_catch,
          flow_node_id: "Throw_1",
          link_name: "A"
        })

      assert result["error_code"] == "no_matching_link_catch"
      assert result["message"] =~ "Link throw event 'Throw_1'"
      assert result["message"] =~ "named 'A'"
    end

    test "every map-shaped handler failure gets a specific sentence" do
      failures = [
        %{reason: :ambiguous_link_catch, flow_node_id: "Throw_1", link_name: "A", catch_count: 2},
        %{reason: :message_name_blank, detail: "MessageDefinition Msg_1 has no name"},
        %{reason: :message_definition_not_found, detail: "No MessageDefinition with id=Msg_1"},
        %{reason: :no_message_ref, detail: "Flow node has no message_ref"},
        %{reason: :signal_name_blank, detail: "SignalDefinition Sig_1 has no name"},
        %{reason: :signal_definition_not_found, detail: "No SignalDefinition with id=Sig_1"},
        %{reason: :no_signal_ref, detail: "Flow node has no signal_ref"},
        %{reason: :unsupported_timer_type, detail: "time_cycle is not supported"},
        %{reason: :missing_timer_spec, detail: "no spec"},
        %{reason: :timer_resolution_failed, detail: :invalid_duration},
        %{reason: :resume_timer_failed, detail: :not_found},
        %{reason: :invalid_subprocess, detail: "Subprocess 'Sub_1' has no End Event"},
        %{reason: :invalid_transaction, detail: "Transaction 'Tx_1' has no End Event"},
        %{reason: :invalid_event_subprocess, detail: "expected exactly one start event"}
      ]

      for failure <- failures do
        result = ErrorInfo.build(failure)
        assert result["error_code"] == Atom.to_string(failure.reason)
        assert String.ends_with?(result["message"], "."), inspect(result)
        refute result["message"] == "An unexpected error occurred"
      end
    end

    test "timer resolution failures name the timer construct and the offending value" do
      expectations = [
        {{:not_a_date_time, 42}, ["timeDate", "42"]},
        {{:not_a_duration, %{"days" => 1}}, ["timeDuration", "a context"]},
        {{:not_a_cycle, 7}, ["timeCycle", "7"]},
        {{:unsupported_time_zone, "2026-06-01T10:00:00@Europe/Berlin"},
         ["2026-06-01T10:00:00@Europe/Berlin", "UTC offset"]},
        {{:invalid_date_time, "tomorrow", :invalid_format}, ["'tomorrow'", "invalid_format"]},
        {{:non_positive_cycle_interval, "PT0S"}, ["timeCycle", "'PT0S'"]}
      ]

      for {detail, fragments} <- expectations do
        message =
          ErrorInfo.build(%{reason: :timer_resolution_failed, detail: detail})["message"]

        for fragment <- fragments, do: assert(message =~ fragment, message)
        refute message =~ "see error details"
      end
    end

    test "data_object_value_null without a transformation names the flow node and the Data Object" do
      result =
        ErrorInfo.build(
          {:data_object_value_null,
           %{flow_node_id: "Task_Produce", data_object_id: "DO_Order", expression: nil}}
        )

      assert result["error_code"] == "data_object_value_null"
      assert result["message"] =~ "'Task_Produce'"
      assert result["message"] =~ "'DO_Order'"
      assert result["message"] =~ "has no transformation"
    end

    test "correlation_expression_failed names the correlation expression" do
      result = ErrorInfo.build({:correlation_expression_failed, "unknown variable 'orderId'"})
      assert result["error_code"] == "correlation_expression_failed"
      assert result["message"] =~ "correlation expression"
      assert result["message"] =~ "unknown variable 'orderId'"
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

    test "process_not_found and no_version_available name the Call Activity" do
      assert ErrorInfo.build(:process_not_found)["message"] =~ "Call Activity"
      assert ErrorInfo.build(:no_version_available)["message"] =~ "no enabled version"
    end

    test "data_object_transformation_failed names the data object and expression" do
      result =
        ErrorInfo.build(
          {:data_object_transformation_failed, "DO_Order",
           {:feel_eval_failed, "token.missing.field", "unknown variable"}}
        )

      assert result["error_code"] == "data_object_transformation_failed"
      assert result["message"] =~ "Writing data object 'DO_Order' failed"
      assert result["message"] =~ "token.missing.field"
      assert result["message"] =~ "unknown variable"
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

    test "invalid_named_script_return" do
      result = ErrorInfo.build({:invalid_named_script_return, :nope})
      assert result["error_code"] == "invalid_named_script_return"
      assert result["message"] =~ "{:ok, map}"
    end

    test "invalid_contract_schema" do
      result = ErrorInfo.build({:invalid_contract_schema, "unresolvable $ref"})
      assert result["error_code"] == "invalid_contract_schema"
      assert result["message"] == "The contract is not a valid JSON Schema: unresolvable $ref"
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

    test "input contract violations name the element and the payload contract" do
      for {code, element} <- [
            {:service_task_input_contract_violation, "Service task"},
            {:script_task_input_contract_violation, "Script task"},
            {:business_rule_task_input_contract_violation, "Business rule task"}
          ] do
        result = ErrorInfo.build({code, [{"is missing", "#/a"}]})
        assert result["error_code"] == Atom.to_string(code)

        assert result["message"] ==
                 "#{element} input does not match the payload contract: #/a: is missing"
      end
    end

    test "output contract violations name the element and the result contract" do
      for {code, element} <- [
            {:script_task_contract_violation, "Script task"},
            {:business_rule_task_contract_violation, "Business rule task"}
          ] do
        result = ErrorInfo.build({code, [%{message: "bad"}]})
        assert result["message"] == "#{element} output does not match the result contract: bad"
      end
    end

    test "payload and result contract violations from message and subprocess elements" do
      payload = ErrorInfo.build({:payload_contract_violation, [{"x", "#/p"}]})
      assert payload["error_code"] == "payload_contract_violation"
      assert payload["message"] =~ "payload contract: #/p: x"

      result = ErrorInfo.build({:result_contract_violation, [{"y", "#/r"}]})
      assert result["error_code"] == "result_contract_violation"
      assert result["message"] =~ "result contract: #/r: y"
    end

    test "value contract violation names the data object" do
      result = ErrorInfo.build({:value_contract_violation, "DO_1", [{"nope", "#/v"}]})
      assert result["error_code"] == "value_contract_violation"

      assert result["message"] ==
               "Data object 'DO_1' value does not match its value contract: #/v: nope"
    end

    test "invalid contract schema is explained" do
      result =
        ErrorInfo.build(
          {:service_task_input_contract_violation, {:invalid_contract_schema, "bad ref"}}
        )

      assert result["message"] =~ "the contract is not a valid JSON Schema: bad ref"
    end

    test "data object and http handler errors have explicit messages" do
      assert ErrorInfo.build({:unknown_data_object_reference, "Ref_1"})["message"] =~ "'Ref_1'"
      assert ErrorInfo.build({:unknown_data_object, "DO_9"})["message"] =~ "'DO_9'"
      assert ErrorInfo.build({:http_handler_missing_url, "Task_1"})["message"] =~ "no bfw:httpUrl"
      assert ErrorInfo.build({:http_handler_invalid_method, "TRACE"})["message"] =~ "'TRACE'"

      assert ErrorInfo.build({:http_response_headers_expression_error, "boom"})["message"] =~
               "bfw:httpResponseHeaders expression failed: boom"

      assert ErrorInfo.build({:http_body_expression_error, "parse error"})["message"] ==
               "HTTP service task bfw:httpBody expression failed: parse error"

      assert ErrorInfo.build({:http_auth_expression_error, "not a string"})["message"] ==
               "HTTP service task bfw:httpAuthHeader expression failed: not a string"
    end

    test "handler_raised is a coded error naming the plugin key, the flow node, and the exception" do
      handler = %{
        flow_node_id: "Task_Charge",
        handler_type: "implementation",
        handler_key: "payments"
      }

      raised = ErrorInfo.handler_raised(handler, :error, %RuntimeError{message: "boom"})

      assert raised.error_code == "handler_raised"

      assert ErrorInfo.build(raised) == %{
               "error_code" => "handler_raised",
               "message" =>
                 "The plugin handler for implementation 'payments' of flow node 'Task_Charge' raised " <>
                   "an exception instead of returning a result: boom"
             }
    end

    test "handler_raised cuts a long exception message and never quotes an exit or throw value" do
      handler = %{flow_node_id: "Script_1", handler_type: "scriptRef", handler_key: "audit"}

      long_raise =
        ErrorInfo.handler_raised(handler, :error, %RuntimeError{
          message: String.duplicate("x", 2_000)
        })

      assert String.length(long_raise.error_message) < 700

      exited =
        ErrorInfo.handler_raised(
          handler,
          :exit,
          {:noproc, {GenServer, :call, [%{"secret" => "s3"}]}}
        )

      assert exited.error_message =~ "exited (a :noproc tuple)"
      refute exited.error_message =~ "s3"

      assert ErrorInfo.handler_raised(handler, :throw, %{"secret" => "s3"}).error_message =~
               "threw a map"

      assert ErrorInfo.handler_raised(handler, :error, :badarg).error_message =~
               "Erlang error (:badarg)"

      assert ErrorInfo.handler_raised(handler, :exit, ["s3"]).error_message =~ "exited (a list)"
    end

    test "an unsupported time zone in a date-time is described without naming timers" do
      message =
        ErrorInfo.build(
          {:user_task_due_date_failed,
           %{
             flow_node_id: "Task_Review",
             expression: "x",
             reason: {:unsupported_time_zone, "2027-01-01T00:00:00[Europe/Berlin]"}
           }}
        )["message"]

      assert message =~ "names a time zone; only a UTC offset such as 'Z' or '+02:00' is accepted"
      refute message =~ "timers"
    end

    test "user_task_due_date_failed names the task, the expression, and the reason" do
      not_a_date_time =
        ErrorInfo.build(
          {:user_task_due_date_failed,
           %{flow_node_id: "Task_Review", expression: "token.days", reason: {:not_a_date_time, 3}}}
        )

      assert not_a_date_time["message"] =~ "'Task_Review'"
      assert not_a_date_time["message"] =~ "'token.days'"
      assert not_a_date_time["message"] =~ "yielded 3, which is not a date or date-time"

      duration =
        ErrorInfo.build(
          {:user_task_due_date_failed,
           %{
             flow_node_id: "Task_Review",
             expression: "x",
             reason: {:not_a_date_time, {:feel_duration_dt, "PT1H"}}
           }}
        )

      assert duration["message"] =~ "yielded the duration PT1H, which is not a date or date-time"

      evaluation_error =
        ErrorInfo.build(
          {:user_task_due_date_failed,
           %{flow_node_id: "Task_Review", expression: "token.(", reason: "parse error"}}
        )

      assert evaluation_error["message"] =~ "bfw:dueDate 'token.('"
      assert evaluation_error["message"] =~ "parse error"
    end

    test "dmn_evaluation_failed with a text detail" do
      assert ErrorInfo.build({:dmn_evaluation_failed, "the evaluator raised"})["message"] ==
               "DMN evaluation failed: the evaluator raised"
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
      violations = [{"must be positive", "#/amount"}]
      result = ErrorInfo.build({:service_task_contract_violation, violations})
      assert result["message"] =~ "#/amount: must be positive"
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

  describe "compensation scope error humanization" do
    test "compensation_scope_failed names the subprocess, its instance, and the inner reason" do
      result =
        ErrorInfo.build(
          {:compensation_scope_failed,
           %{
             subprocess_flow_node_id: "SubProcess_Booking",
             child_process_instance_id: "child-1",
             reason: %{
               "error_code" => "compensation_handler_fatal",
               "message" => "Compensation handler 'Task_Undo' went fatal."
             }
           }}
        )

      assert result["error_code"] == "compensation_scope_failed"

      assert result["message"] ==
               "Compensating the inner activities of subprocess 'SubProcess_Booking' failed in " <>
                 "its instance 'child-1': Compensation handler 'Task_Undo' went fatal."

      assert result["detail"]["reason"]["error_code"] == "compensation_handler_fatal"
    end

    test "compensation_scope_start_failed names the subprocess, its instance, and the start reason" do
      result =
        ErrorInfo.build(
          {:compensation_scope_start_failed,
           %{
             subprocess_flow_node_id: "SubProcess_Booking",
             child_process_instance_id: "child-1",
             reason: :process_instance_not_found
           }}
        )

      assert result["error_code"] == "compensation_scope_start_failed"

      assert result["message"] ==
               "Subprocess 'SubProcess_Booking' could not be compensated because its instance " <>
                 "'child-1' could not be started again: process_instance_not_found."
    end

    test "compensation_handler_dispatch_failed names the handler and the unsupported node" do
      result =
        ErrorInfo.build(
          {:compensation_handler_dispatch_failed,
           %{
             handler_activity_id: "Start_Undo_Book",
             reason: {:unsupported_event_definition, %{id: "Start_Undo_Book"}}
           }}
        )

      assert result["error_code"] == "compensation_handler_dispatch_failed"

      assert result["message"] ==
               "Compensation handler 'Start_Undo_Book' could not be started, so the compensation " <>
                 "did not complete: the engine has no handler for the event definition of flow " <>
                 "node 'Start_Undo_Book'."
    end

    test "compensation_handler_dispatch_failed formats an atom reason" do
      result =
        ErrorInfo.build(
          {:compensation_handler_dispatch_failed,
           %{handler_activity_id: "Task_Undo", reason: :persistence_unavailable}}
        )

      assert result["message"] =~ "'Task_Undo' could not be started"
      assert result["message"] =~ "persistence_unavailable"
    end

    test "process_instance_crashed quotes an exception message, capped" do
      reason = {%RuntimeError{message: String.duplicate("x", 600)}, []}
      result = ErrorInfo.build(ErrorInfo.process_instance_crashed("pi-1", reason))

      assert result["error_code"] == "process_instance_crashed"
      assert result["message"] =~ "process instance 'pi-1' crashed with an exception: xxx"
      refute result["message"] =~ String.duplicate("x", 501)
    end

    test "process_instance_crashed names only the shape of an exit reason" do
      result =
        ErrorInfo.build(ErrorInfo.process_instance_crashed("pi-2", {:badmatch, %{"secret" => 1}}))

      assert result["message"] ==
               "The process of process instance 'pi-2' crashed with exit reason a :badmatch " <>
                 "tuple, so the instance and its active flow node instances were set to fatal."
    end

    test "child_record_failed names the child that was not started" do
      result =
        ErrorInfo.build(
          {:child_record_failed,
           %{child_process_instance_id: "child-2", reason: :connection_lost}}
        )

      assert result["error_code"] == "child_record_failed"

      assert result["message"] ==
               "After an engine restart, the shell could not record its new child process " <>
                 "instance 'child-2' in the database (connection_lost), so the child was not started."
    end

    test "compensation_handler_fatal names the handler activity" do
      result = ErrorInfo.build({:compensation_handler_fatal, "Task_Undo_Book"})

      assert result["error_code"] == "compensation_handler_fatal"

      assert result["message"] ==
               "Compensation handler 'Task_Undo_Book' went fatal, so the compensation of its " <>
                 "subprocess did not complete."
    end
  end
end
