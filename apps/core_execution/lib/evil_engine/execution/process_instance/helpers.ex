defmodule EvilEngine.Execution.ProcessInstance.Helpers do
  @moduledoc """
  Pure utility functions extracted from `ProcessInstance`.

  These are stateless helpers used across the PI, boundary orchestration,
  resumption, and FNI lifecycle modules. Imported into `ProcessInstance`
  so call sites remain unchanged.
  """

  require Logger

  alias EvilEngine.BPMN.ComplexRegionAnalysis
  alias EvilEngine.BPMN.InclusiveJoinAnalysis
  alias EvilEngine.BPMN.Model.EventDefinition
  alias EvilEngine.BPMN.Model.FlowNode
  alias EvilEngine.BPMN.ModelCache
  alias EvilEngine.Execution.HandlerContext
  alias EvilEngine.Execution.HandlerDispatch
  alias EvilEngine.Expressions.Context, as: FeelContext

  @event_definition_type_map %{
    EventDefinition.Message => "message",
    EventDefinition.Signal => "signal",
    EventDefinition.Timer => "timer",
    EventDefinition.Error => "error",
    EventDefinition.Escalation => "escalation",
    EventDefinition.Conditional => "conditional",
    EventDefinition.Compensation => "compensation",
    EventDefinition.Terminate => "terminate",
    EventDefinition.Cancel => "cancel",
    EventDefinition.Link => "link"
  }

  @spec generate_id() :: String.t()
  def generate_id do
    timestamp_ms = System.system_time(:millisecond)
    <<rand_a::12, rand_b::62, _::6>> = :crypto.strong_rand_bytes(10)

    <<timestamp_ms::48, 7::4, rand_a::12, 2::2, rand_b::62>>
    |> Base.encode16(case: :lower)
    |> then(fn <<a::binary-8, b::binary-4, c::binary-4, d::binary-4, e::binary-12>> ->
      "#{a}-#{b}-#{c}-#{d}-#{e}"
    end)
  end

  @spec resolve_lane_name(struct(), FlowNode.t()) :: String.t() | nil
  def resolve_lane_name(process_model, flow_node) do
    lane =
      Enum.find(process_model.lanes, fn lane ->
        flow_node.id in (lane.flow_node_refs || [])
      end)

    if lane, do: lane.name, else: nil
  end

  @spec fetch_process_model(String.t(), String.t() | nil) ::
          {:ok, struct(), struct()} | {:error, term()}
  def fetch_process_model(process_version_id, subprocess_node_id \\ nil)

  def fetch_process_model(process_version_id, nil) do
    case ModelCache.fetch(process_version_id) do
      {:ok, definitions} ->
        case Enum.find(definitions.processes, & &1.is_executable) do
          nil ->
            {:error, :no_executable_process}

          process ->
            enriched_process =
              process
              |> InclusiveJoinAnalysis.enrich_process()
              |> ComplexRegionAnalysis.enrich_process()

            {:ok, enriched_process, definitions}
        end

      error ->
        error
    end
  end

  def fetch_process_model(process_version_id, subprocess_node_id) do
    case ModelCache.fetch_subprocess_model(process_version_id, subprocess_node_id) do
      {:ok, subprocess_model, definitions} ->
        enriched_subprocess =
          subprocess_model
          |> InclusiveJoinAnalysis.enrich_process()
          |> ComplexRegionAnalysis.enrich_process()

        {:ok, enriched_subprocess, definitions}

      error ->
        error
    end
  end

  @spec find_flow_node(struct(), String.t()) :: FlowNode.t() | nil
  def find_flow_node(data, flow_node_id) do
    Enum.find(data.process_model.flow_nodes, &(&1.id == flow_node_id))
  end

  @spec extract_event_type(FlowNode.t()) :: String.t() | nil
  def extract_event_type(%FlowNode{type: type})
      when type in [:send_task, :receive_task],
      do: "message"

  def extract_event_type(%FlowNode{type_data: %{event_definition: %{__struct__: module}}}) do
    Map.get(@event_definition_type_map, module)
  end

  def extract_event_type(%FlowNode{}), do: nil

  @doc """
  Build a structured error_info map for an unsupported BPMN event definition.

  Includes the flow node id, flow node type, and event definition type so
  callers can diagnose which element was reached without implementation support.
  """
  @spec build_unsupported_event_definition_error_info(FlowNode.t()) :: %{String.t() => term()}
  def build_unsupported_event_definition_error_info(%FlowNode{} = flow_node) do
    event_type = extract_event_type(flow_node) || "unknown"
    flow_node_type = Atom.to_string(flow_node.type)

    %{
      "error_code" => "unsupported_event_definition",
      "message" =>
        "Unsupported event definition '#{event_type}' on flow node '#{flow_node.id}' (#{flow_node_type})",
      "detail" => %{
        "flow_node_id" => flow_node.id,
        "flow_node_type" => flow_node_type,
        "event_type" => event_type
      }
    }
  end

  @spec parse_flow_node_type(atom() | String.t()) :: atom()
  def parse_flow_node_type(type) when is_atom(type), do: type
  def parse_flow_node_type(type) when is_binary(type), do: String.to_existing_atom(type)

  @spec stringify_keys(map() | nil) :: map() | nil
  def stringify_keys(nil), do: nil

  def stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  @doc """
  Build a normalized error_info map with a consistent schema:

    %{"error_code" => ..., "message" => ..., "detail" => ...}

  Accepts the wide range of error shapes produced by handlers:
  - `%{error_code: c, error_message: m}` (fail_async_service_task)
  - `{:crash, reason}` (FNI process crash)
  - `%{reason: r}` (generic handler errors)
  - atoms, tuples, strings, maps
  """
  @spec build_error_info(term()) :: %{String.t() => term()}
  def build_error_info(%{error_code: code, error_message: message}) do
    %{
      "error_code" => to_string(code),
      "message" => to_string(message)
    }
  end

  def build_error_info(%{"error_code" => code, "error_message" => message}) do
    %{
      "error_code" => to_string(code),
      "message" => to_string(message)
    }
  end

  def build_error_info({:crash, reason}) do
    %{
      "error_code" => "crash",
      "message" => "Flow node instance process crashed",
      "detail" => to_json_safe(reason)
    }
  end

  def build_error_info({error_code, detail_one, detail_two}) when is_atom(error_code) do
    %{
      "error_code" => Atom.to_string(error_code),
      "message" => humanize_error({error_code, detail_one, detail_two}),
      "detail" => to_json_safe([detail_one, detail_two])
    }
  end

  def build_error_info({error_code, detail}) when is_atom(error_code) do
    %{
      "error_code" => Atom.to_string(error_code),
      "message" => humanize_error({error_code, detail}),
      "detail" => to_json_safe(detail)
    }
  end

  def build_error_info(reason) when is_atom(reason) do
    %{
      "error_code" => Atom.to_string(reason),
      "message" => humanize_error(reason)
    }
  end

  def build_error_info(reason) when is_binary(reason) do
    %{
      "error_code" => "error",
      "message" => reason
    }
  end

  def build_error_info(%{} = map) do
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
    |> Map.put("detail", to_json_safe(map))
  end

  def build_error_info(reason) do
    Logger.warning("Unrecognized error shape in build_error_info: #{inspect(reason)}")

    %{
      "error_code" => "error",
      "message" => "An unexpected error occurred",
      "detail" => to_json_safe(reason)
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

  defp humanize_error({:mixed_gateway, %{flow_node_id: id, incoming_count: incoming, outgoing_count: outgoing}}) do
    "Complex gateway '#{id}' is a mixed gateway (#{incoming} incoming, #{outgoing} outgoing). " <>
      "A Complex Gateway must be either a split or a join, not both."
  end

  defp humanize_error({:complex_split_no_matching_condition, %{flow_node_id: id}}) do
    "Complex gateway '#{id}' has no outgoing flow with a fulfilled condition and no default " <>
      "flow to fall back on."
  end

  defp humanize_error({:complex_split_condition_failed, %{flow_node_id: id, sequence_flow_id: flow_id, reason: reason}}) do
    "Complex gateway '#{id}': failed to evaluate the condition on sequence flow " <>
      "'#{flow_id}': #{reason}"
  end

  defp humanize_error({:complex_join_condition_unmet, detail}) do
    "Complex join '#{detail.flow_node_id}': all branches have finished but the gateway's " <>
      "activation condition '#{detail.activation_condition}' was not met " <>
      "(activatedCount=#{detail.activated_count}, incomingCount=#{detail.incoming_count})."
  end

  defp humanize_error({:complex_join_condition_failed, %{flow_node_id: id, activation_condition: condition, reason: reason}}) do
    "Complex join '#{id}': failed to evaluate the activation condition '#{condition}': #{reason}"
  end

  defp humanize_error({:duplicate_join_arrival, %{flow_node_id: id, incoming_flow_id: flow_id}}) do
    "A duplicate token arrived at join '#{id}' via sequence flow '#{flow_id}'."
  end

  defp humanize_error({:ambiguous_start_event, _detail}) do
    "Called process has multiple start events but no startEventId was specified"
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
  @spec sanitize_error_info(map() | nil) :: map() | nil
  def sanitize_error_info(nil), do: nil

  def sanitize_error_info(%{"message" => message} = error_info) do
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

  def sanitize_error_info(other), do: other

  @doc false
  def looks_like_elixir_internal?(message) when is_binary(message) do
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

  def looks_like_elixir_internal?(_), do: false

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

  @spec to_json_safe(term()) :: nil | boolean() | binary() | number() | [any()] | map()
  def to_json_safe(nil), do: nil

  def to_json_safe(value) when is_binary(value) or is_number(value) or is_boolean(value),
    do: value

  def to_json_safe(value) when is_atom(value), do: Atom.to_string(value)

  def to_json_safe(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.map(&to_json_safe/1)

  def to_json_safe(value) when is_list(value), do: Enum.map(value, &to_json_safe/1)

  def to_json_safe(%{__struct__: _} = value) do
    value
    |> Map.from_struct()
    |> Map.delete(:__meta__)
    |> to_json_safe()
  end

  def to_json_safe(value) when is_map(value) do
    Map.new(value, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), to_json_safe(v)}
      {k, v} when is_binary(k) -> {k, to_json_safe(v)}
      {k, v} -> {inspect(k), to_json_safe(v)}
    end)
  end

  def to_json_safe(value), do: inspect(value)

  @spec find_fni_by_pid(struct(), pid()) :: {String.t(), map()} | nil
  def find_fni_by_pid(data, pid) do
    Enum.find(data.flow_node_instance_states, fn {_id, entry} -> entry.pid == pid end)
  end

  @spec resolve_host_fni_id(struct(), String.t()) :: String.t()
  def resolve_host_fni_id(data, boundary_fni_id) do
    case Map.get(data.flow_node_instance_states, boundary_fni_id) do
      %{type_properties: %{host_flow_node_instance_id: host_id}} when is_binary(host_id) ->
        host_id

      %{type_properties: %{"host_flow_node_instance_id" => host_id}} when is_binary(host_id) ->
        host_id

      _ ->
        boundary_fni_id
    end
  end

  @spec boundary_fni_for_host?(map(), String.t()) :: boolean()
  def boundary_fni_for_host?(entry, host_fni_id) do
    type_props = entry.type_properties || %{}

    host_ref =
      Map.get(type_props, :host_flow_node_instance_id) ||
        Map.get(type_props, "host_flow_node_instance_id")

    host_ref == host_fni_id
  end

  @spec invoke_optional_callback(FlowNode.t() | nil, atom(), list()) :: :ok
  def invoke_optional_callback(flow_node, callback_name, args) do
    with {:ok, handler} <- HandlerDispatch.handler_for(flow_node),
         true <- function_exported?(handler, callback_name, length(args)) do
      apply(handler, callback_name, args)
    end

    :ok
  end

  @spec build_handler_context(struct(), String.t(), FlowNode.t(), pid()) :: HandlerContext.t()
  def build_handler_context(data, flow_node_instance_id, flow_node, process_instance_pid) do
    identity_map =
      case data.identity do
        nil -> %{}
        %{__struct__: _} = identity -> Map.from_struct(identity)
        identity when is_map(identity) -> identity
      end

    process_map =
      case data.process_model do
        nil ->
          %{}

        process_model ->
          %{id: process_model.id, name: process_model.name, version: process_model.version}
      end

    %HandlerContext{
      flow_node_instance_id: flow_node_instance_id,
      process_instance_id: data.process_instance_id,
      root_process_instance_id: data.root_process_instance_id,
      process_version_id: data.process_version_id,
      process_instance_pid: process_instance_pid,
      process_model: data.process_model,
      definitions: data.definitions,
      flow_node_this: FeelContext.flow_node_this(flow_node),
      context: data.started_with_context || %{},
      identity: identity_map,
      process: process_map,
      process_instance: %{
        id: data.process_instance_id,
        started_at: data.started_at,
        started_by: identity_map[:id]
      },
      data_objects: data.data_object_cache
    }
  end

  @spec dispatch_handler_result(pid(), String.t(), term()) :: :ok
  def dispatch_handler_result(
        process_instance_pid,
        flow_node_instance_id,
        {:async, flow_node_instance_id, continuation_function, type_properties}
      )
      when is_function(continuation_function, 0) and is_map(type_properties) do
    send(
      process_instance_pid,
      {:fni_result, flow_node_instance_id, {:async, flow_node_instance_id, type_properties}}
    )

    final_result = continuation_function.()
    send(process_instance_pid, {:fni_result, flow_node_instance_id, final_result})
  end

  def dispatch_handler_result(
        process_instance_pid,
        flow_node_instance_id,
        {:async, flow_node_instance_id, continuation_function}
      )
      when is_function(continuation_function, 0) do
    send(
      process_instance_pid,
      {:fni_result, flow_node_instance_id, {:async, flow_node_instance_id}}
    )

    final_result = continuation_function.()
    send(process_instance_pid, {:fni_result, flow_node_instance_id, final_result})
  end

  def dispatch_handler_result(process_instance_pid, flow_node_instance_id, result) do
    send(process_instance_pid, {:fni_result, flow_node_instance_id, result})
  end

  @spec parse_fni_state(atom() | String.t()) :: atom()
  def parse_fni_state(state) when is_atom(state), do: state
  def parse_fni_state("active"), do: :active
  def parse_fni_state("waiting"), do: :waiting
  def parse_fni_state("finished"), do: :finished
  def parse_fni_state("fatal"), do: :fatal
  def parse_fni_state("aborted"), do: :aborted
  def parse_fni_state("interrupted"), do: :interrupted
  def parse_fni_state("error"), do: :error
  def parse_fni_state("cancelled"), do: :aborted
end
