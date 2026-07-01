defmodule EvilEngine.Execution.FlowNodes.SignalEventHelper do
  @moduledoc """
  Shared logic used by all signal event handlers.

  Much simpler than `MessageEventHelper` since signals have no
  correlation and no payload contracts. The only concern is resolving
  the signal name from the event definition's `signal_ref` via the
  global `SignalDefinition` in the process model's definitions.
  """

  alias EvilEngine.BPMN.Model.Definitions
  alias EvilEngine.BPMN.Model.FlowNode

  @doc """
  Resolve the BPMN signal name from a flow node's event definition
  `signal_ref` by looking up the global `SignalDefinition` in the
  process model's definitions.

  Returns `{:ok, signal_name}` or `{:error, reason}`.
  """
  @spec resolve_signal_name(FlowNode.t(), Definitions.t()) :: {:ok, String.t()} | {:error, term()}
  def resolve_signal_name(flow_node, %Definitions{} = definitions) do
    signal_ref = flow_node.type_data.event_definition.signal_ref

    case find_signal_definition(definitions, signal_ref) do
      {:ok, signal_def} ->
        if signal_def.name && signal_def.name != "" do
          {:ok, signal_def.name}
        else
          {:error,
           %{
             reason: :signal_name_blank,
             detail: "SignalDefinition #{signal_ref} has no name"
           }}
        end

      {:error, _} = error ->
        error
    end
  end

  # -------------------------------------------------------------------
  # Private helpers
  # -------------------------------------------------------------------

  defp find_signal_definition(%Definitions{signals: signals}, signal_ref)
       when is_binary(signal_ref) do
    case Enum.find(signals, fn sig -> sig.id == signal_ref end) do
      nil ->
        {:error,
         %{
           reason: :signal_definition_not_found,
           detail: "No SignalDefinition with id=#{signal_ref}"
         }}

      signal_def ->
        {:ok, signal_def}
    end
  end

  defp find_signal_definition(_definitions, _signal_ref) do
    {:error, %{reason: :no_signal_ref, detail: "Flow node has no signal_ref"}}
  end
end
