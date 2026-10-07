defmodule BfwEngine.Execution.ProcessInstance.ErrorInfo do
  @moduledoc """
  Builds the normalized error_info map stored on fatal flow-node instances.
  """

  require Logger

  alias BfwEngine.Execution.ProcessInstance.JsonSafe

  @doc """
  Build a normalized error_info map with a consistent schema:

    %{"error_code" => ..., "message" => ..., "detail" => ...}

  Accepts the wide range of error shapes produced by handlers:
  - `%{error_code: c, error_message: m}` (fail_async_service_task)
  - `{:crash, reason}` (FNI process crash)
  - `%{reason: r}` (generic handler errors)
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

  defp humanize_error({:service_task_contract_violation, violations}) do
    "Service task output does not match the result contract: #{format_violations_summary(violations)}"
  end

  defp humanize_error({:user_task_input_contract_violation, violations}) do
    "User task input does not match the payload contract: #{format_violations_summary(violations)}"
  end

  defp humanize_error({:contract_violation, violations}) do
    "Output does not match the result contract: #{format_violations_summary(violations)}"
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

  defp humanize_error({:decision_not_found, ref}) do
    "DMN decision '#{ref}' is not deployed"
  end

  defp humanize_error({:decision_disabled, ref}) do
    "DMN decision '#{ref}' is disabled"
  end

  defp humanize_error({:dmn_evaluation_failed, type, _metadata}) do
    "DMN evaluation failed (#{type})"
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

  defp humanize_error({:called_element_resolution_failed, detail}) do
    "Could not resolve the called process for this Call Activity: #{format_detail(detail)}"
  end

  defp humanize_error({:called_process_version_not_found, process_model_id, version_string}) do
    "Could not resolve called process '#{process_model_id}' at version '#{version_string}'. The pin must match an existing <bfw:version> string of that process; typing 'latest' looks up a version actually named latest."
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

  defp format_detail(detail) when is_tuple(detail),
    do: detail |> Tuple.to_list() |> Enum.map_join(", ", &format_detail/1)

  defp format_detail(detail) when is_map(detail) and is_map_key(detail, :message),
    do: detail.message

  defp format_detail(detail) when is_map(detail) and is_map_key(detail, "message"),
    do: detail["message"]

  defp format_detail(_detail), do: "see error details"

  defp format_violations_summary(violations) when is_list(violations) do
    violations
    |> Enum.take(3)
    |> Enum.map_join("; ", fn
      %{message: message} -> message
      %{"message" => message} -> message
      {path, message} -> "#{path}: #{message}"
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
