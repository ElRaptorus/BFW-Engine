defmodule BfwEngine.Execution.ProcessInstance.ErrorInfo do
  @moduledoc """
  Builds the normalized error_info map stored on fatal flow-node instances.
  """

  require Logger

  alias BfwEngine.Execution.ProcessInstance.JsonSafe

  @raised_message_max_length 500

  @doc """
  Builds the coded error for a plugin handler (a Service Task
  `implementation` or a Named Script `scriptRef`) whose `handle_enter/3`
  raised, exited, or threw: `%{error_code: "handler_raised", error_message: sentence}`.
  Error boundaries and Error Event Subprocess starts match the code like any
  other coded error.

  `handler` carries `:flow_node_id`, `:handler_type` (`"implementation"` or
  `"scriptRef"`), and `:handler_key`. The sentence quotes an exception's
  message, cut to #{@raised_message_max_length} characters; for an exit, a
  throw, or a raw Erlang error it names only the shape of the value, never the
  value.
  """
  @spec handler_raised(
          %{flow_node_id: String.t(), handler_type: String.t(), handler_key: String.t()},
          :error | :exit | :throw,
          term()
        ) :: %{error_code: String.t(), error_message: String.t()}
  def handler_raised(
        %{flow_node_id: flow_node_id, handler_type: handler_type, handler_key: handler_key},
        kind,
        value
      ) do
    %{
      error_code: "handler_raised",
      error_message:
        "The plugin handler for #{handler_type} '#{handler_key}' of flow node '#{flow_node_id}' " <>
          raise_description(kind, value)
    }
  end

  @doc """
  Build a normalized error_info map with a consistent schema:

    %{"error_code" => ..., "message" => ..., "detail" => ...}

  Accepts the wide range of error shapes produced by handlers:
  - `%{error_code: c, error_message: m}` (fail_async_service_task)
  - `{:crash, reason}` (FNI process crash)
  - `%{reason: atom}` (handler errors): the atom is the error_code; the message is the
    map's `:message`, else a `humanize_error/1` clause
  - `%{reason: r}` with a non-atom reason (generic handler errors)
  - atoms, tuples, strings, maps
  """
  @spec build(term()) :: %{String.t() => term()}
  def build(%{error_code: code, error_message: message}) do
    %{
      "error_code" => to_string(code),
      "message" => to_string(message)
    }
  end

  def build(%{"error_code" => code, "error_message" => message}) do
    %{
      "error_code" => to_string(code),
      "message" => to_string(message)
    }
  end

  def build({:crash, reason}) do
    %{
      "error_code" => "crash",
      "message" => "Flow node instance process crashed",
      "detail" => JsonSafe.convert(reason)
    }
  end

  def build({error_code, detail_one, detail_two}) when is_atom(error_code) do
    %{
      "error_code" => Atom.to_string(error_code),
      "message" => humanize_error({error_code, detail_one, detail_two}),
      "detail" => JsonSafe.convert([detail_one, detail_two])
    }
  end

  def build({error_code, detail}) when is_atom(error_code) do
    %{
      "error_code" => Atom.to_string(error_code),
      "message" => humanize_error({error_code, detail}),
      "detail" => JsonSafe.convert(detail)
    }
  end

  def build(reason) when is_atom(reason) do
    %{
      "error_code" => Atom.to_string(reason),
      "message" => humanize_error(reason)
    }
  end

  def build(reason) when is_binary(reason) do
    %{
      "error_code" => "error",
      "message" => reason
    }
  end

  def build(%{reason: reason} = map) when is_atom(reason) and not is_nil(reason) do
    message =
      case Map.get(map, :message) do
        message when is_binary(message) -> message
        _ -> humanize_error({reason, map})
      end

    %{
      "error_code" => Atom.to_string(reason),
      "message" => message,
      "detail" => JsonSafe.convert(map)
    }
  end

  def build(%{} = map) do
    base = %{"error_code" => "error", "message" => "error"}

    base
    |> maybe_put_from(map, "error_code", [:error_code, "error_code"])
    |> maybe_put_from(map, "message", [
      :message,
      "message",
      :error_message,
      "error_message",
      :reason,
      "reason"
    ])
    |> Map.put("detail", JsonSafe.convert(map))
  end

  def build(reason) do
    Logger.warning("Unrecognized error shape in ErrorInfo.build: #{inspect(reason)}")

    %{
      "error_code" => "error",
      "message" => "An unexpected error occurred",
      "detail" => JsonSafe.convert(reason)
    }
  end

  defp humanize_error({:in_mapping_failed, {:feel_eval_failed, expression, reason}}) do
    "Input mapping failed: FEEL expression '#{expression}' could not be evaluated — #{reason}"
  end

  defp humanize_error({:out_mapping_failed, {:feel_eval_failed, expression, reason}}) do
    "Output mapping failed: FEEL expression '#{expression}' could not be evaluated — #{reason}"
  end

  defp humanize_error({:in_mapping_failed, detail}) do
    "Input mapping failed: #{format_detail(detail)}"
  end

  defp humanize_error({:out_mapping_failed, detail}) do
    "Output mapping failed: #{format_detail(detail)}"
  end

  defp humanize_error({:feel_eval_failed, expression, reason}) do
    "FEEL expression '#{expression}' could not be evaluated: #{reason}"
  end

  defp humanize_error({:missing_implementation, task_id}) do
    "Service task '#{task_id}' has no implementation attribute"
  end

  defp humanize_error({:no_handler_for_implementation, implementation}) do
    "No handler registered for implementation '#{implementation}'. Is the plugin loaded?"
  end

  defp humanize_error({:service_task_input_contract_violation, violations}) do
    input_violation_message("Service task", violations)
  end

  defp humanize_error({:service_task_contract_violation, violations}) do
    output_violation_message("Service task", violations)
  end

  defp humanize_error({:script_task_input_contract_violation, violations}) do
    input_violation_message("Script task", violations)
  end

  defp humanize_error({:script_task_contract_violation, violations}) do
    output_violation_message("Script task", violations)
  end

  defp humanize_error({:business_rule_task_input_contract_violation, violations}) do
    input_violation_message("Business rule task", violations)
  end

  defp humanize_error({:business_rule_task_contract_violation, violations}) do
    output_violation_message("Business rule task", violations)
  end

  defp humanize_error({:user_task_input_contract_violation, violations}) do
    input_violation_message("User task", violations)
  end

  defp humanize_error({:contract_violation, violations}) do
    "Output does not match the result contract: #{format_violations_summary(violations)}"
  end

  defp humanize_error({:payload_contract_violation, violations}) do
    "Input does not match the payload contract: #{format_violations_summary(violations)}"
  end

  defp humanize_error({:result_contract_violation, violations}) do
    "Output does not match the result contract: #{format_violations_summary(violations)}"
  end

  defp humanize_error({:value_contract_violation, data_object_id, violations}) do
    "Data object '#{data_object_id}' value does not match its value contract: " <>
      format_violations_summary(violations)
  end

  defp humanize_error(
         {:data_object_transformation_failed, data_object_id,
          {:feel_eval_failed, expression, reason}}
       ) do
    "Writing data object '#{data_object_id}' failed: the data output association's transformation " <>
      "'#{expression}' could not be evaluated — #{format_detail(reason)}"
  end

  defp humanize_error({:unknown_data_object_reference, reference}) do
    "Data output association targets '#{format_detail(reference)}', which is not a data object reference in this process"
  end

  defp humanize_error({:unknown_data_object, data_object_id}) do
    "Data object reference points to data object '#{format_detail(data_object_id)}', which is not declared in this process"
  end

  defp humanize_error({:http_handler_missing_url, flow_node_id}) do
    "HTTP service task '#{format_detail(flow_node_id)}' has no bfw:httpUrl"
  end

  defp humanize_error({:http_handler_invalid_method, method}) do
    "HTTP service task has unsupported method '#{format_detail(method)}' (expected GET, POST, PUT, PATCH, DELETE, HEAD, or OPTIONS)"
  end

  defp humanize_error({:http_response_headers_expression_error, detail}) do
    "HTTP service task bfw:httpResponseHeaders expression failed: #{format_detail(detail)}"
  end

  defp humanize_error({:http_body_expression_error, detail}) do
    "HTTP service task bfw:httpBody expression failed: #{format_detail(detail)}"
  end

  defp humanize_error({:http_auth_expression_error, detail}) do
    "HTTP service task bfw:httpAuthHeader expression failed: #{format_detail(detail)}"
  end

  defp humanize_error(
         {:user_task_due_date_failed,
          %{flow_node_id: flow_node_id, expression: expression, reason: {:not_a_date_time, value}}}
       ) do
    "User task '#{flow_node_id}' could not resolve its bfw:dueDate '#{expression}': the FEEL " <>
      "expression yielded #{feel_value_text(value)}, which is not a date or date-time."
  end

  defp humanize_error(
         {:user_task_due_date_failed,
          %{flow_node_id: flow_node_id, expression: expression, reason: reason}}
       ) do
    "User task '#{flow_node_id}' could not resolve its bfw:dueDate '#{expression}' (neither an ISO 8601 " <>
      "date-time nor a FEEL expression yielding one): #{format_detail(reason)}."
  end

  defp humanize_error({:script_eval_failed, _script_text, reason}) do
    "Script evaluation failed: #{reason}"
  end

  defp humanize_error({:missing_script, message}) when is_binary(message) do
    message
  end

  defp humanize_error({:no_handler_for_script_ref, ref}) do
    "No named script plugin registered for scriptRef '#{ref}'"
  end

  defp humanize_error({:named_script_failed, ref, reason}) do
    "Named script '#{ref}' failed: #{format_detail(reason)}"
  end

  defp humanize_error({:invalid_named_script_return, _detail}) do
    "Named script returned an invalid result; it must return {:ok, map} or {:error, reason}"
  end

  defp humanize_error({:invalid_contract_schema, message}) when is_binary(message) do
    "The contract is not a valid JSON Schema: #{message}"
  end

  defp humanize_error({:decision_not_found, ref}) do
    "DMN decision '#{ref}' is not deployed"
  end

  defp humanize_error({:decision_disabled, ref}) do
    "DMN decision '#{ref}' is disabled"
  end

  defp humanize_error({:dmn_evaluation_failed, type, _metadata}) do
    "DMN evaluation failed (#{type})"
  end

  defp humanize_error({:dmn_evaluation_failed, detail}) when is_binary(detail) do
    "DMN evaluation failed: #{detail}"
  end

  defp humanize_error({:dmn_evaluation_timeout, %{timeout_ms: timeout_ms}}) do
    "DMN evaluation timed out after #{timeout_ms}ms"
  end

  defp humanize_error({:dmn_evaluation_timeout, _detail}) do
    "DMN evaluation timed out"
  end

  defp humanize_error({:payload_too_large, %{size: size, limit: limit}}) do
    "Payload size (#{size} bytes) exceeds limit (#{limit} bytes)"
  end

  defp humanize_error({:payload_too_large, _detail}) do
    "Payload exceeds the configured size limit"
  end

  defp humanize_error({:called_process_version_not_found, process_model_id, version_string}) do
    "Could not resolve called process '#{process_model_id}' at version '#{version_string}'. The pin must match an existing <bfw:version> string of that process; typing 'latest' looks up a version actually named latest."
  end

  defp humanize_error(:process_not_found) do
    "The called process is not deployed or is disabled in the engine catalog, so this Call Activity cannot start it."
  end

  defp humanize_error(:no_version_available) do
    "The called process has no enabled version, so this Call Activity cannot start it."
  end

  defp humanize_error(:version_disabled) do
    "The called process is disabled in the engine catalog, so this Call Activity cannot start it."
  end

  defp humanize_error({:no_matching_condition, %{message: message}}) when is_binary(message) do
    message
  end

  defp humanize_error({:dead_end, %{message: message}}) when is_binary(message) do
    message
  end

  defp humanize_error({:implicit_split, %{message: message}}) when is_binary(message) do
    message
  end

  defp humanize_error({:invalid_handler_return, _detail}) do
    "Flow node handler returned an invalid result"
  end

  defp humanize_error({:persistence_failed, _detail}) do
    "Failed to persist state to database"
  end

  defp humanize_error({:unknown_brt_implementation, implementation}) do
    "Business rule task has unsupported implementation '#{implementation}' (expected 'feel' or 'dmn')"
  end

  defp humanize_error({:start_event_not_found, event_id}) do
    "Start event '#{event_id}' not found in the called process"
  end

  defp humanize_error(
         {:mixed_gateway, %{flow_node_id: id, incoming_count: incoming, outgoing_count: outgoing}}
       ) do
    "Complex gateway '#{id}' is a mixed gateway (#{incoming} incoming, #{outgoing} outgoing). " <>
      "A Complex Gateway must be either a split or a join, not both."
  end

  defp humanize_error({:complex_split_no_matching_condition, %{flow_node_id: id}}) do
    "Complex gateway '#{id}' has no outgoing flow with a fulfilled condition and no default " <>
      "flow to fall back on."
  end

  defp humanize_error(
         {:complex_split_condition_failed,
          %{flow_node_id: id, sequence_flow_id: flow_id, reason: reason}}
       ) do
    "Complex gateway '#{id}': failed to evaluate the condition on sequence flow " <>
      "'#{flow_id}': #{reason}"
  end

  defp humanize_error({:complex_join_condition_unmet, detail}) do
    "Complex join '#{detail.flow_node_id}': all branches have finished but the gateway's " <>
      "activation condition '#{detail.activation_condition}' was not met " <>
      "(activatedCount=#{detail.activated_count}, incomingCount=#{detail.incoming_count})."
  end

  defp humanize_error(
         {:complex_join_condition_failed,
          %{flow_node_id: id, activation_condition: condition, reason: reason}}
       ) do
    "Complex join '#{id}': failed to evaluate the activation condition '#{condition}': #{reason}"
  end

  defp humanize_error({:duplicate_join_arrival, %{flow_node_id: id, incoming_flow_id: flow_id}}) do
    "A duplicate token arrived at join '#{id}' via sequence flow '#{flow_id}'."
  end

  defp humanize_error(
         {:loop_condition_failed,
          %{flow_node_id: id, condition: condition, expression: expression, reason: reason}}
       ) do
    "Loop activity '#{id}' could not evaluate its #{condition} '#{expression}': #{reason}."
  end

  defp humanize_error({:ambiguous_start_event, _detail}) do
    "Called process has multiple start events but no startEventId was specified"
  end

  defp humanize_error(:interrupted_by_event_subprocess) do
    "This flow node was interrupted because an interrupting Event Subprocess in " <>
      "the enclosing scope was triggered, cancelling all other work in the scope."
  end

  defp humanize_error(:orphan_subprocess_start) do
    "Cannot start a process instance scoped to an embedded subprocess directly: " <>
      "a subprocess node was targeted without a parent process instance. Start Events " <>
      "inside embedded, event, or transactional subprocesses are reachable only when the " <>
      "owning subprocess element is executed by its parent process."
  end

  defp humanize_error(:cancel_end_outside_transaction) do
    "Cancel End Event reached outside a Transaction subprocess scope. " <>
      "Cancel End Events are only valid inside a bpmn:transaction element."
  end

  defp humanize_error(:cancel_boundary_not_dispatched) do
    "Cancel Boundary Event was directly dispatched, which is a bug. " <>
      "Cancel Boundary Events are reactive — they are resolved by the TransactionSubProcess handler " <>
      "when the child PI reports cancellation, not dispatched directly."
  end

  defp humanize_error(
         {:collection_exceeds_max_iterations, %{collection_size: size, max_iterations: max}}
       ) do
    "Parallel Multi-Instance input collection has #{size} items but maxIterations is #{max}. " <>
      "Increase maxIterations, reduce the collection, or use Sequential Multi-Instance."
  end

  defp humanize_error({:adhoc_subprocess_empty, message}) when is_binary(message) do
    message
  end

  defp humanize_error(:retry_inside_adhoc_subprocess) do
    "Cannot retry a process instance inside an ad-hoc subprocess scope"
  end

  defp humanize_error(:not_adhoc_subprocess) do
    "Process instance is not an ad-hoc subprocess"
  end

  defp humanize_error(:adhoc_activity_not_found) do
    "Activity not found in ad-hoc subprocess scope"
  end

  defp humanize_error(:adhoc_already_completing) do
    "Ad-hoc subprocess completion has already been signaled"
  end

  defp humanize_error(:dispatch_failed) do
    "Failed to dispatch ad-hoc activity flow node instance"
  end

  defp humanize_error({:no_matching_link_catch, %{flow_node_id: id, link_name: link_name}}) do
    "Link throw event '#{id}' has no matching link catch event named '#{link_name}' in this process."
  end

  defp humanize_error(
         {:ambiguous_link_catch, %{flow_node_id: id, link_name: link_name, catch_count: count}}
       ) do
    "Link throw event '#{id}' matches #{count} link catch events named '#{link_name}'; " <>
      "a link name must identify exactly one catch event."
  end

  defp humanize_error({:message_name_blank, %{detail: detail}}) do
    "Cannot route the message: #{detail}. Every bpmn:message needs a non-blank name."
  end

  defp humanize_error({:message_definition_not_found, %{detail: detail}}) do
    "The flow node's messageRef does not resolve to a global bpmn:message: #{detail}."
  end

  defp humanize_error({:no_message_ref, _detail}) do
    "The message flow node has no messageRef, so the engine cannot tell which message to send or wait for."
  end

  defp humanize_error({:signal_name_blank, %{detail: detail}}) do
    "Cannot route the signal: #{detail}. Every bpmn:signal needs a non-blank name."
  end

  defp humanize_error({:signal_definition_not_found, %{detail: detail}}) do
    "The flow node's signalRef does not resolve to a global bpmn:signal: #{detail}."
  end

  defp humanize_error({:no_signal_ref, _detail}) do
    "The signal flow node has no signalRef, so the engine cannot tell which signal to send or wait for."
  end

  defp humanize_error({:unsupported_timer_type, _detail}) do
    "A timeCycle is not supported on an intermediate catch event; use timeDate or timeDuration."
  end

  defp humanize_error({:missing_timer_spec, _detail}) do
    "The timer event definition has no timeDate, timeDuration, or timeCycle, so the engine cannot schedule it."
  end

  defp humanize_error({:timer_resolution_failed, %{detail: detail}}) do
    "The timer definition could not be resolved to a fire time: #{format_detail(detail)}."
  end

  defp humanize_error({:resume_timer_failed, %{detail: detail}}) do
    "The timer could not be re-armed after the process instance resumed: #{format_detail(detail)}."
  end

  defp humanize_error({:invalid_subprocess, %{detail: detail}}) do
    "#{detail}."
  end

  defp humanize_error({:invalid_transaction, %{detail: detail}}) do
    "#{detail}."
  end

  defp humanize_error({:invalid_event_subprocess, %{detail: detail}}) do
    "The event subprocess is invalid: #{detail}."
  end

  defp humanize_error({:correlation_expression_failed, reason}) do
    "The message correlation expression could not be evaluated: #{format_detail(reason)}."
  end

  defp humanize_error(
         {:event_subprocess_correlation_failed, subprocess_node_id,
          %{expression: expression, reason: reason}}
       ) do
    "The correlation key '#{expression}' for the message start event of Event Subprocess " <>
      "'#{subprocess_node_id}' could not be evaluated when its scope started: " <>
      "#{format_detail(reason)}."
  end

  defp humanize_error({:lost_successor_repair_failed, flow_node_id, failure}) do
    "After an engine restart, flow node '#{flow_node_id}' had finished but its successors had " <>
      "not been created, and resolving its outgoing sequence flows again failed: " <>
      "#{format_detail(failure)}."
  end

  defp humanize_error(
         {:child_resume_failed,
          %{child_process_instance_id: child_process_instance_id, reason: reason}}
       ) do
    "After an engine restart, the row of child process instance '#{child_process_instance_id}' " <>
      "could not be read from the database (#{format_detail(reason)}), so the shell neither " <>
      "resumed that child nor started a second one."
  end

  defp humanize_error(
         {:event_subprocess_timer_resolution_failed, subprocess_node_id,
          %{expression: expression, reason: reason}}
       ) do
    "The timer '#{expression}' of the start event of Event Subprocess '#{subprocess_node_id}' " <>
      "could not be resolved to a fire time when its scope started, so the Event Subprocess " <>
      "could never fire: #{format_detail(reason)}."
  end

  defp humanize_error(
         {:data_object_value_null,
          %{flow_node_id: flow_node_id, data_object_id: data_object_id, expression: nil}}
       ) do
    "Flow node '#{flow_node_id}' cannot write data object '#{data_object_id}': its data output " <>
      "association has no transformation and the flow node's output is null; a data object " <>
      "needs a value."
  end

  defp humanize_error(
         {:data_object_value_null,
          %{flow_node_id: flow_node_id, data_object_id: data_object_id, expression: expression}}
       ) do
    "Flow node '#{flow_node_id}' cannot write data object '#{data_object_id}': the transformation " <>
      "'#{expression}' of its data output association evaluated to null; a data object needs a value."
  end

  defp humanize_error(
         {:compensation_scope_failed,
          %{
            subprocess_flow_node_id: subprocess_flow_node_id,
            child_process_instance_id: child_process_instance_id,
            reason: %{"message" => message}
          }}
       ) do
    "Compensating the inner activities of subprocess '#{subprocess_flow_node_id}' failed in its " <>
      "instance '#{child_process_instance_id}': #{String.trim_trailing(message, ".")}."
  end

  defp humanize_error(
         {:compensation_scope_start_failed,
          %{
            subprocess_flow_node_id: subprocess_flow_node_id,
            child_process_instance_id: child_process_instance_id,
            reason: reason
          }}
       ) do
    "Subprocess '#{subprocess_flow_node_id}' could not be compensated because its instance " <>
      "'#{child_process_instance_id}' could not be started again: #{format_detail(reason)}."
  end

  defp humanize_error({:compensation_handler_fatal, handler_activity_id}) do
    "Compensation handler '#{handler_activity_id}' went fatal, so the compensation of its " <>
      "subprocess did not complete."
  end

  defp humanize_error({error_code, detail}) when is_atom(error_code) and is_binary(detail) do
    "#{atom_to_words(error_code)}: #{detail}"
  end

  defp humanize_error({error_code, _detail}) when is_atom(error_code) do
    atom_to_words(error_code)
  end

  defp humanize_error(reason) when is_atom(reason) do
    atom_to_words(reason)
  end

  defp humanize_error(_reason) do
    "An unexpected error occurred"
  end

  defp atom_to_words(atom) do
    atom
    |> Atom.to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp format_detail(detail) when is_binary(detail), do: detail
  defp format_detail(detail) when is_atom(detail), do: Atom.to_string(detail)

  defp format_detail({:feel_eval_failed, expression, reason}),
    do: "FEEL expression '#{expression}' — #{reason}"

  defp format_detail({:not_a_date_time, value}),
    do: "the timeDate expression yielded #{feel_value_text(value)}, which is not a date-time"

  defp format_detail({:not_a_duration, value}),
    do: "the timeDuration expression yielded #{feel_value_text(value)}, which is not a duration"

  defp format_detail({:not_a_cycle, value}) do
    "the timeCycle expression yielded #{feel_value_text(value)}, which is not an ISO 8601 " <>
      "repeating interval string such as 'R3/PT1H'"
  end

  defp format_detail({:unsupported_time_zone, text}) do
    "the date-time '#{text}' names a time zone; only a UTC offset such as 'Z' or '+02:00' " <>
      "is accepted"
  end

  defp format_detail({:invalid_date_time, text, reason}),
    do: "'#{text}' is not a valid ISO 8601 date-time (#{format_detail(reason)})"

  defp format_detail({:non_positive_cycle_interval, text}),
    do:
      "the timeCycle interval '#{text}' is not positive; a cycle needs an interval greater than zero"

  defp format_detail(detail) when is_tuple(detail),
    do: detail |> Tuple.to_list() |> Enum.map_join(", ", &format_detail/1)

  defp format_detail(detail) when is_map(detail) and is_map_key(detail, :message),
    do: detail.message

  defp format_detail(detail) when is_map(detail) and is_map_key(detail, "message"),
    do: detail["message"]

  defp format_detail(_detail), do: "see error details"

  defp feel_value_text(nil), do: "null"
  defp feel_value_text(value) when is_binary(value), do: "'#{value}'"
  defp feel_value_text(value) when is_number(value) or is_boolean(value), do: to_string(value)
  defp feel_value_text(value) when is_list(value), do: "a list"
  defp feel_value_text(value) when is_map(value), do: "a context"

  defp feel_value_text({duration_type, text})
       when duration_type in [:feel_duration_dt, :feel_duration_ym],
       do: "the duration #{text}"

  defp feel_value_text(_value), do: "a value of another FEEL type"

  defp input_violation_message(element, violations) do
    "#{element} input does not match the payload contract: #{format_violations_summary(violations)}"
  end

  defp output_violation_message(element, violations) do
    "#{element} output does not match the result contract: #{format_violations_summary(violations)}"
  end

  defp format_violations_summary({:invalid_contract_schema, message}) do
    "the contract is not a valid JSON Schema: #{message}"
  end

  defp format_violations_summary(violations) when is_list(violations) do
    violations
    |> Enum.take(3)
    |> Enum.map_join("; ", fn
      %{message: message} -> message
      %{"message" => message} -> message
      {message, path} when is_binary(message) and is_binary(path) -> "#{path}: #{message}"
      other when is_binary(other) -> other
      other -> inspect(other)
    end)
    |> then(fn summary ->
      remaining = length(violations) - 3

      if remaining > 0, do: "#{summary} (and #{remaining} more)", else: summary
    end)
  end

  defp format_violations_summary(_violations), do: "contract violation"

  @doc """
  Last-mile defense: replace raw Elixir internal strings in error_info messages
  with a generic, user-safe sentence.
  """
  @spec sanitize(map() | nil) :: map() | nil
  def sanitize(nil), do: nil

  def sanitize(%{"message" => message} = error_info) do
    if looks_like_elixir_internal?(message) do
      error_code = Map.get(error_info, "error_code", "error")

      Logger.warning("Sanitizing raw Elixir error in FNI event: #{message}")

      %{
        error_info
        | "message" =>
            "An error occurred (error code: #{error_code}). Check the process debugger for details."
      }
    else
      error_info
    end
  end

  def sanitize(other), do: other

  defp looks_like_elixir_internal?(message) when is_binary(message) do
    String.contains?(message, [
      "%{",
      "#PID<",
      "Elixir.",
      "**",
      "no function clause",
      "FunctionClauseError",
      "ArgumentError"
    ])
  end

  defp looks_like_elixir_internal?(_), do: false

  defp raise_description(:error, exception) when is_exception(exception) do
    "raised an exception instead of returning a result: " <>
      String.slice(Exception.message(exception), 0, @raised_message_max_length)
  end

  defp raise_description(:error, value),
    do: "raised an Erlang error (#{term_shape(value)}) instead of returning a result"

  defp raise_description(:exit, value),
    do: "exited (#{term_shape(value)}) instead of returning a result"

  defp raise_description(:throw, value),
    do: "threw #{term_shape(value)} instead of returning a result"

  defp term_shape(value) when is_atom(value), do: inspect(value)

  defp term_shape(value) when tuple_size(value) > 0 and is_atom(elem(value, 0)),
    do: "a #{inspect(elem(value, 0))} tuple"

  defp term_shape(value) when is_tuple(value), do: "a tuple"
  defp term_shape(value) when is_map(value), do: "a map"
  defp term_shape(value) when is_list(value), do: "a list"
  defp term_shape(value) when is_binary(value), do: "a string"
  defp term_shape(value) when is_number(value), do: "a number"
  defp term_shape(_value), do: "a value"

  defp maybe_put_from(target, source, target_key, source_keys) do
    value =
      Enum.find_value(source_keys, fn key ->
        case Map.get(source, key) do
          nil -> nil
          v -> to_string(v)
        end
      end)

    if value, do: Map.put(target, target_key, value), else: target
  end
end
