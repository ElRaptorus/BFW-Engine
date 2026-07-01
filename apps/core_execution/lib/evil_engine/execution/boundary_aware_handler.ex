defmodule EvilEngine.Execution.BoundaryAwareHandler do
  @moduledoc """
  Middleware that wraps any activity handler's `handle_enter/3` with
  error boundary resolution.

  If the inner handler returns `{:error, reason}` and the flow node has
  attached error boundary events, this wrapper checks `BoundaryResolver`
  for a matching error boundary. On match, the error is converted to
  `{:boundary, node_id, error_info, cancel_activity}`. All other return
  shapes pass through unchanged.

  Non-activity types (events, gateways) bypass the wrapper entirely —
  their `{:error, ...}` returns pass through without boundary checks
  because only activities can have attached boundary events.

  This closes the gap identified in plan section C8: prior to this
  wrapper, only `CallActivity` performed error boundary resolution
  (and only for child PI errors). With this wrapper, all activity
  handlers get error boundary coverage for their `handle_enter` errors.
  """

  alias EvilEngine.BPMN.Model.FlowNode
  alias EvilEngine.Execution.BoundaryResolver
  alias EvilEngine.Execution.FlowNodeResult
  alias EvilEngine.Execution.HandlerContext
  alias EvilEngine.Types.Token

  @activity_types [
    :task,
    :service_task,
    :user_task,
    :manual_task,
    :script_task,
    :business_rule_task,
    :send_task,
    :receive_task,
    :call_activity,
    :sub_process
  ]

  @doc """
  Wraps a handler module's `handle_enter/3` with error boundary resolution.

  Returns the handler's result unchanged unless it is `{:error, reason}`
  on an activity type with attached error boundary events.
  """
  @spec wrap_enter(module(), FlowNode.t(), Token.t(), HandlerContext.t()) ::
          {:ok, FlowNodeResult.t()}
          | {:wait, FlowNodeResult.t()}
          | {:async, String.t()}
          | {:async, String.t(), (-> term())}
          | {:async, String.t(), (-> term()), map()}
          | {:boundary, String.t(), term(), boolean()}
          | {:error, term()}
  def wrap_enter(handler_module, flow_node, token, context) do
    result = handler_module.handle_enter(flow_node, token, context)

    case result do
      {:error, reason} when flow_node.type in @activity_types ->
        attempt_error_boundary_catch(flow_node, context, reason)

      other ->
        other
    end
  end

  @doc false
  @spec attempt_error_boundary_catch(FlowNode.t(), HandlerContext.t(), term()) ::
          {:boundary, String.t(), map(), boolean()} | {:error, term()}
  def attempt_error_boundary_catch(flow_node, context, reason) do
    if has_error_boundaries?(flow_node, context.process_model) do
      error_info = normalize_to_error_info(reason)

      case BoundaryResolver.find_matching_error_boundary(
             flow_node,
             context.process_model,
             error_info
           ) do
        {:ok, boundary_node} ->
          cancel = Map.get(boundary_node.type_data, :cancel_activity, true)
          {:boundary, boundary_node.id, error_info, cancel}

        :none ->
          {:error, reason}
      end
    else
      {:error, reason}
    end
  end

  @doc """
  Normalizes arbitrary error reasons into the structured
  `%{error_code: ..., error_message: ...}` shape expected by
  `BoundaryResolver`.

  Already-structured maps (with `:error_code`) pass through unchanged.
  All other shapes are wrapped with a generic `"HANDLER_ERROR"` code.
  """
  @spec normalize_to_error_info(term()) :: BoundaryResolver.error_info()
  def normalize_to_error_info(%{error_code: _} = already_structured),
    do: already_structured

  def normalize_to_error_info(reason) when is_binary(reason),
    do: %{error_code: "HANDLER_ERROR", error_message: reason}

  def normalize_to_error_info(reason),
    do: %{error_code: "HANDLER_ERROR", error_message: inspect(reason)}

  defp has_error_boundaries?(%FlowNode{boundary_event_refs: refs}, process_model)
       when is_list(refs) and refs != [] do
    node_index = Map.new(process_model.flow_nodes, &{&1.id, &1})

    Enum.any?(refs, fn ref_id ->
      case Map.get(node_index, ref_id) do
        %FlowNode{type: :boundary_event, type_data: type_data} ->
          match?(%EvilEngine.BPMN.Model.EventDefinition.Error{}, type_data.event_definition)

        _ ->
          false
      end
    end)
  end

  defp has_error_boundaries?(_, _), do: false
end
