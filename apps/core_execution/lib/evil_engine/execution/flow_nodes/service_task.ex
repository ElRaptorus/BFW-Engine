defmodule EvilEngine.Execution.FlowNodes.ServiceTask do
  @moduledoc """
  Handler for `<bpmn:serviceTask>`.

  Dispatches to a plugin-registered handler based on the BPMN standard
  `implementation` attribute. The actual handler module is resolved at
  runtime through `ServiceTaskDispatch` (DI boundary to the Plugin
  Registry).

  ## Data pipeline

  Input pipeline (runs in `handle_enter/3`):

      token -> in_mappings -> payload_contract -> plugin dispatch ({:async, ref})

  Output pipeline (runs in `handle_complete/4` when the plugin calls
  `finish_async_service_task`):

      async result -> out_mappings -> result_contract -> PayloadCap -> downstream

  All contract violations and FEEL evaluation failures transition
  the FNI to `:fatal` (service tasks have no interactive retry path).

  ## Async-only contract

  Service Task handlers always return `{:async, ref}`. The engine does
  not accept synchronous `{:ok, %FlowNodeResult{}}` returns from
  plugins. This enforces a clear boundary: Service Tasks represent
  external delegation; local computation belongs in Script Tasks.

  ## Completion

  `handle_complete/4` is called when an external actor completes an
  async FNI via `finish_async_service_task`. The output pipeline runs
  here.
  """

  @behaviour EvilEngine.Execution.FlowNodeHandler

  alias EvilEngine.BPMN.Model.FlowNode
  alias EvilEngine.Execution.FlowNodeResult
  alias EvilEngine.Execution.FniLifecycle
  alias EvilEngine.Execution.HandlerContext
  alias EvilEngine.Execution.MappingHelper
  alias EvilEngine.Execution.SequenceFlowResolver
  alias EvilEngine.Execution.ServiceTaskDispatch
  alias EvilEngine.Types.Token

  @spec handle_enter(FlowNode.t(), Token.t(), HandlerContext.t()) ::
          {:async, String.t(), map()} | {:error, term()}
  @impl true
  def handle_enter(flow_node, token, context) do
    type_data = flow_node.type_data
    implementation = type_data.implementation

    with :ok <- validate_implementation(flow_node.id, implementation),
         {:ok, handler_module} <- lookup_handler(implementation),
         {:ok, mapped_input} <- apply_input_pipeline(type_data, token.payload, context) do
      mapped_token = %{token | payload: mapped_input}
      dispatch_and_park(handler_module, flow_node, mapped_token, context)
    end
  end

  @spec handle_complete(FlowNode.t(), map(), map(), HandlerContext.t()) ::
          {:ok, FlowNodeResult.t()} | {:error, term()}
  @impl true
  def handle_complete(flow_node, _entry, payload, context) do
    type_data = flow_node.type_data

    with {:ok, mapped_output} <-
           MappingHelper.apply_out_mappings(type_data.out_mappings, payload, context),
         :ok <- validate_result_contract(type_data.result_contract, mapped_output),
         {:ok, next_ids} <- resolve_outgoing(flow_node, context),
         {:ok, lifecycle_result} <- FniLifecycle.finish(context, flow_node, mapped_output, %{}) do
      {:ok,
       %FlowNodeResult{
         output_payload: mapped_output,
         next_flow_node_ids: next_ids,
         metadata: %{persisted: true, lifecycle: lifecycle_result}
       }}
    else
      {:error, {:feel_eval_failed, _source, _reason} = detail} ->
        {:error, {:out_mapping_failed, detail}}

      {:error, {:payload_too_large, _details}} = error ->
        error

      {:error, violations} when is_list(violations) ->
        {:error, {:service_task_contract_violation, violations}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp dispatch_and_park(handler_module, flow_node, mapped_token, context) do
    case dispatch_to_handler(handler_module, flow_node, mapped_token, context) do
      {:async, flow_node_instance_id} ->
        case FniLifecycle.park_async(context, %{}) do
          :ok -> {:async, flow_node_instance_id, %{persisted: true}}
          {:error, :persistence_failed} -> {:error, :persistence_failed}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # -- Input pipeline: in_mappings -> payload_contract -----------------------

  defp apply_input_pipeline(type_data, payload, context) do
    with {:ok, mapped} <- MappingHelper.apply_in_mappings(type_data.in_mappings, payload, context),
         :ok <- validate_payload_contract(type_data.payload_contract, mapped) do
      {:ok, mapped}
    else
      {:error, {:feel_eval_failed, _source, _reason} = detail} ->
        {:error, {:in_mapping_failed, detail}}

      {:error, violations} ->
        {:error, {:service_task_contract_violation, violations}}
    end
  end

  # -- Contract validation ---------------------------------------------------

  defp validate_payload_contract(nil, _payload), do: :ok

  defp validate_payload_contract(contract, payload),
    do: MappingHelper.validate_contract(contract, payload)

  defp validate_result_contract(nil, _payload), do: :ok

  defp validate_result_contract(contract, payload),
    do: MappingHelper.validate_contract(contract, payload)

  # -- Helpers ---------------------------------------------------------------

  defp validate_implementation(task_id, nil), do: {:error, {:missing_implementation, task_id}}
  defp validate_implementation(task_id, ""), do: {:error, {:missing_implementation, task_id}}
  defp validate_implementation(_task_id, _implementation), do: :ok

  defp lookup_handler(implementation) do
    case ServiceTaskDispatch.adapter().lookup_handler(implementation) do
      {:ok, module} -> {:ok, module}
      {:error, :not_found} -> {:error, {:no_handler_for_implementation, implementation}}
    end
  end

  defp resolve_outgoing(flow_node, context) do
    case SequenceFlowResolver.resolve(flow_node, context.process_model) do
      {:ok, targets} -> {:ok, Enum.map(targets, & &1.id)}
      {:error, reason, meta} -> {:error, Map.put(meta, :reason, reason)}
    end
  end

  defp dispatch_to_handler(handler_module, flow_node, token, context) do
    case handler_module.handle_enter(flow_node, token, context) do
      {:async, flow_node_instance_id} -> {:async, flow_node_instance_id}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_handler_return, other}}
    end
  end
end
