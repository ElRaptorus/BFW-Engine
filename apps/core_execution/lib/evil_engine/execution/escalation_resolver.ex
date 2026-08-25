defmodule EvilEngine.Execution.EscalationResolver do
  @moduledoc """
  Resolves escalation codes from `EventDefinition.Escalation` event definitions
  and locates matching escalation boundary events on host activities.

  ## Escalation code resolution

  `EventDefinition.Escalation` may carry an inline `escalation_code`
  (same precedence as throw-side `resolve_escalation_info/2`). When that
  field is blank, the runtime looks up `escalation_ref` on the global
  `EscalationDefinition` in `Definitions.escalations`.

  ## Boundary matching semantics

  - If the boundary's global `EscalationDefinition` specifies a non-nil
    `escalation_code`, the raised escalation must carry the same code.
  - A catch-all boundary (`escalation_ref = nil` or referenced definition has
    `escalation_code = nil`) matches any escalation.
  - Both interrupting and non-interrupting boundaries are returned where noted;
    the caller is responsible for the first-interrupting-wins rule.
  """

  alias EvilEngine.BPMN.Model.Definitions
  alias EvilEngine.BPMN.Model.EscalationDefinition
  alias EvilEngine.BPMN.Model.EventDefinition
  alias EvilEngine.BPMN.Model.FlowNode

  @type escalation_info :: %{
          optional(:escalation_code) => String.t() | nil,
          optional(:escalation_name) => String.t() | nil
        }

  # ---------------------------------------------------------------------------
  # Throw-side: resolve escalation_info from an EventDefinition
  # ---------------------------------------------------------------------------

  @doc """
  Resolves an `EventDefinition.Escalation` into an `escalation_info` map by
  looking up the global `EscalationDefinition` in `definitions`.

  Returns `%{escalation_code: code_or_nil, escalation_name: name_or_nil}`.
  """
  @spec resolve_escalation_info(EventDefinition.Escalation.t(), Definitions.t()) ::
          escalation_info()
  # Inline `escalation_code` takes precedence, mirroring the ESP trigger
  # registration (`ProcessInstance.resolve_esp_escalation_code/2`) and the
  # inline `evil:errorCode` pattern for errors. Without this, a throw carrying
  # an inline code could never match an ESP escalation start declared with the
  # same inline code. The name is only available from a referenced global
  # `<bpmn:escalation>`, so it stays `nil` for a purely inline code.
  def resolve_escalation_info(
        %EventDefinition.Escalation{escalation_code: code},
        _definitions
      )
      when is_binary(code) and code != "" do
    %{escalation_code: code, escalation_name: nil}
  end

  def resolve_escalation_info(
        %EventDefinition.Escalation{escalation_ref: escalation_ref},
        definitions
      )
      when is_binary(escalation_ref) do
    case find_escalation_definition(escalation_ref, definitions) do
      %EscalationDefinition{escalation_code: code, name: name} ->
        %{escalation_code: code, escalation_name: name}

      nil ->
        %{escalation_code: nil, escalation_name: nil}
    end
  end

  def resolve_escalation_info(%EventDefinition.Escalation{}, _definitions) do
    %{escalation_code: nil, escalation_name: nil}
  end

  # ---------------------------------------------------------------------------
  # Catch-side: locate matching boundaries
  # ---------------------------------------------------------------------------

  @doc """
  Finds the first *interrupting* escalation boundary event attached to
  `host_node` that matches `escalation_info`, or `:none`.

  The boundary's escalation code is resolved from `definitions` at match time.

  ## Matching priority

  Per BPMN 2.0 semantics, a boundary with a specific `escalationCode` always
  takes precedence over a catch-all boundary (one with no code). This is
  enforced regardless of the order of `host_node.boundary_event_refs` — a
  consequence of `link_boundary_refs` running before `Enum.reverse` in the
  SAX parser, which can produce reverse-document order.

  Selection algorithm:
  1. Collect all interrupting escalation boundaries.
  2. Try to find the first one whose `escalationCode` equals `raised_code`.
  3. If no specific match, try to find the first catch-all (nil code).
  """
  @spec find_first_interrupting_escalation_boundary(
          FlowNode.t(),
          struct(),
          Definitions.t(),
          escalation_info()
        ) ::
          {:ok, FlowNode.t()} | :none
  def find_first_interrupting_escalation_boundary(
        %FlowNode{} = host_node,
        process_model,
        definitions,
        escalation_info
      ) do
    node_index = Map.new(process_model.flow_nodes, &{&1.id, &1})
    raised_code = Map.get(escalation_info, :escalation_code)

    interrupting_escalation_boundaries =
      host_node.boundary_event_refs
      |> Enum.map(&Map.get(node_index, &1))
      |> Enum.reject(&is_nil/1)
      |> Enum.filter(&(escalation_boundary?(&1) and interrupting?(&1)))

    specific_match =
      Enum.find(interrupting_escalation_boundaries, fn node ->
        boundary_code = resolve_boundary_code(node, definitions)
        not is_nil(boundary_code) and boundary_code == raised_code
      end)

    result =
      specific_match ||
        Enum.find(interrupting_escalation_boundaries, fn node ->
          is_nil(resolve_boundary_code(node, definitions))
        end)

    case result do
      nil -> :none
      node -> {:ok, node}
    end
  end

  @doc """
  Finds all *non-interrupting* escalation boundary events attached to
  `host_node` that match `escalation_info`.

  The boundary's escalation code is resolved from `definitions` at match time.
  """
  @spec find_non_interrupting_escalation_boundaries(
          FlowNode.t(),
          struct(),
          Definitions.t(),
          escalation_info()
        ) :: [FlowNode.t()]
  def find_non_interrupting_escalation_boundaries(
        %FlowNode{} = host_node,
        process_model,
        definitions,
        escalation_info
      ) do
    node_index = Map.new(process_model.flow_nodes, &{&1.id, &1})

    host_node.boundary_event_refs
    |> Enum.map(&Map.get(node_index, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(&escalation_boundary?/1)
    |> Enum.reject(&interrupting?/1)
    |> Enum.filter(&matches_escalation?(&1, definitions, escalation_info))
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp find_escalation_definition(escalation_ref, %Definitions{escalations: escalations}) do
    Enum.find(escalations, &(&1.id == escalation_ref))
  end

  defp escalation_boundary?(%FlowNode{type: :boundary_event, type_data: type_data}) do
    match?(%EventDefinition.Escalation{}, type_data.event_definition)
  end

  defp escalation_boundary?(_), do: false

  defp interrupting?(%FlowNode{type_data: type_data}), do: type_data.cancel_activity

  defp resolve_boundary_code(%FlowNode{type_data: type_data}, definitions) do
    %EventDefinition.Escalation{} = event_definition = type_data.event_definition

    inline_code = event_definition.escalation_code

    cond do
      is_binary(inline_code) and inline_code != "" ->
        inline_code

      is_binary(event_definition.escalation_ref) ->
        case find_escalation_definition(event_definition.escalation_ref, definitions) do
          %EscalationDefinition{escalation_code: code} -> code
          nil -> nil
        end

      true ->
        nil
    end
  end

  defp matches_escalation?(%FlowNode{} = node, definitions, escalation_info) do
    boundary_code = resolve_boundary_code(node, definitions)
    raised_code = Map.get(escalation_info, :escalation_code)
    boundary_code == nil or boundary_code == raised_code
  end
end
