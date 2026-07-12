defmodule EvilEngine.Execution.BoundaryResolver do
  @moduledoc """
  Resolves whether an error raised by a flow node (or a child PI)
  is caught by one of the host activity's attached error boundary events.

  Matching semantics follow SS7 AND logic:
  - If the boundary specifies `error_code` only, the runtime error must
    carry the same code.
  - If the boundary specifies `error_message` only, the runtime error
    must carry the same message.
  - If the boundary specifies both, **both** must match.
  - A catch-all boundary (no `error_code`, no `error_message`) matches
    any error.
  """

  alias EvilEngine.BPMN.Model.EventDefinition
  alias EvilEngine.BPMN.Model.FlowNode

  @type error_info :: %{
          optional(:error_code) => String.t(),
          optional(:error_message) => String.t()
        }

  @doc """
  Scans the host activity's `boundary_event_refs` for an error boundary
  event whose event definition matches `error_info`.

  Returns `{:ok, boundary_flow_node}` for the first match, or `:none`.
  """
  @spec find_matching_error_boundary(FlowNode.t(), struct(), error_info()) ::
          {:ok, FlowNode.t()} | :none
  def find_matching_error_boundary(%FlowNode{} = host_node, process_model, error_info) do
    node_index = Map.new(process_model.flow_nodes, &{&1.id, &1})

    host_node.boundary_event_refs
    |> Enum.map(&Map.get(node_index, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(&error_boundary?/1)
    |> Enum.find(&matches_error?(&1, error_info))
    |> case do
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

  defp matches_error?(%FlowNode{type_data: type_data}, error_info) do
    %EventDefinition.Error{} = error_def = type_data.event_definition

    code_matches?(error_def.error_code, error_info) and
      message_matches?(error_def.error_message, error_info)
  end

  defp code_matches?(nil, _error_info), do: true

  defp code_matches?(expected, error_info),
    do: to_string(Map.get(error_info, :error_code)) == expected

  defp message_matches?(nil, _error_info), do: true
  defp message_matches?(expected, error_info), do: Map.get(error_info, :error_message) == expected
end
