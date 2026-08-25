defmodule EvilEngine.Execution.BoundaryResolver do
  @moduledoc """
  Resolves whether an error raised by a flow node (or a child PI)
  is caught by one of the host activity's attached error boundary events.

  Catch-code resolution (mirrors throw-side `ErrorEndEvent`):
  1. Inline `error_code` (`evil:errorCode`) if present
  2. Else global `<bpmn:error errorCode>` via `error_ref`
  3. Else `nil` (catch-all)

  Ranking among error boundaries on the same host (document order is
  not used as a specificity tiebreak):
  1. First boundary whose resolved code equals the raised `error_code`
     (and the message AND-filter still holds)
  2. Else first catch-all (resolved code `nil`, message filter ok)

  Matching semantics follow SS7 AND logic:
  - If the boundary specifies `error_code` only, the runtime error must
    carry the same code.
  - If the boundary specifies `error_message` only, the runtime error
    must carry the same message.
  - If the boundary specifies both, **both** must match.
  - A catch-all boundary (no resolved code, no `error_message`) matches
    any error.
  """

  alias EvilEngine.BPMN.Model.Definitions
  alias EvilEngine.BPMN.Model.ErrorDefinition
  alias EvilEngine.BPMN.Model.EventDefinition
  alias EvilEngine.BPMN.Model.FlowNode

  @type error_info :: %{
          optional(:error_code) => String.t(),
          optional(:error_message) => String.t()
        }

  @doc """
  Scans the host activity's `boundary_event_refs` for an error boundary
  event whose event definition matches `error_info`.

  The 3-arity form is kept for tests that do not supply `Definitions`;
  `error_ref` lookup is then a no-op (inline `error_code` only).

  Returns `{:ok, boundary_flow_node}` for the ranked match, or `:none`.
  """
  @spec find_matching_error_boundary(FlowNode.t(), struct(), error_info()) ::
          {:ok, FlowNode.t()} | :none
  def find_matching_error_boundary(%FlowNode{} = host_node, process_model, error_info) do
    find_matching_error_boundary(host_node, process_model, nil, error_info)
  end

  @spec find_matching_error_boundary(FlowNode.t(), struct(), Definitions.t() | nil, error_info()) ::
          {:ok, FlowNode.t()} | :none
  def find_matching_error_boundary(
        %FlowNode{} = host_node,
        process_model,
        definitions,
        error_info
      ) do
    node_index = Map.new(process_model.flow_nodes, &{&1.id, &1})
    raised_code = Map.get(error_info, :error_code)

    error_boundaries =
      host_node.boundary_event_refs
      |> Enum.map(&Map.get(node_index, &1))
      |> Enum.reject(&is_nil/1)
      |> Enum.filter(&error_boundary?/1)

    specific_match =
      Enum.find(error_boundaries, fn node ->
        resolved_code = resolve_catch_code(node, definitions)

        not is_nil(resolved_code) and resolved_code == to_string_or_nil(raised_code) and
          message_matches?(error_message_on(node), error_info)
      end)

    result =
      specific_match ||
        Enum.find(error_boundaries, fn node ->
          is_nil(resolve_catch_code(node, definitions)) and
            message_matches?(error_message_on(node), error_info)
        end)

    case result do
      nil -> :none
      node -> {:ok, node}
    end
  end

  @doc """
  Scans the transaction shell's `boundary_event_refs` for a Cancel Boundary
  Event.

  Cancel Boundary Events have no discriminator — any Cancel Boundary on the
  transaction shell catches the cancel. Returns `{:ok, boundary_flow_node}`
  for the first Cancel Boundary found, or `:none`.
  """
  @spec find_matching_cancel_boundary(FlowNode.t(), struct()) :: {:ok, FlowNode.t()} | :none
  def find_matching_cancel_boundary(%FlowNode{} = host_node, process_model) do
    node_index = Map.new(process_model.flow_nodes, &{&1.id, &1})

    host_node.boundary_event_refs
    |> Enum.map(&Map.get(node_index, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.find(&cancel_boundary?/1)
    |> case do
      nil -> :none
      node -> {:ok, node}
    end
  end

  defp cancel_boundary?(%FlowNode{type: :boundary_event, type_data: type_data}) do
    match?(%EventDefinition.Cancel{}, type_data.event_definition)
  end

  defp cancel_boundary?(_), do: false

  defp error_boundary?(%FlowNode{type: :boundary_event, type_data: type_data}) do
    match?(%EventDefinition.Error{}, type_data.event_definition)
  end

  defp error_boundary?(_), do: false

  defp error_message_on(%FlowNode{type_data: type_data}) do
    %EventDefinition.Error{error_message: error_message} = type_data.event_definition
    error_message
  end

  defp resolve_catch_code(%FlowNode{type_data: type_data}, definitions) do
    %EventDefinition.Error{} = error_definition = type_data.event_definition
    inline_code = error_definition.error_code

    cond do
      is_binary(inline_code) and inline_code != "" ->
        inline_code

      is_binary(error_definition.error_ref) ->
        lookup_global_error_code(error_definition.error_ref, definitions)

      true ->
        nil
    end
  end

  defp lookup_global_error_code(_error_ref, nil), do: nil

  defp lookup_global_error_code(error_ref, %Definitions{errors: errors}) do
    case Enum.find(errors, &(&1.id == error_ref)) do
      %ErrorDefinition{error_code: error_code} -> error_code
      nil -> nil
    end
  end

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(value), do: to_string(value)

  defp message_matches?(nil, _error_info), do: true
  defp message_matches?(expected, error_info), do: Map.get(error_info, :error_message) == expected
end
