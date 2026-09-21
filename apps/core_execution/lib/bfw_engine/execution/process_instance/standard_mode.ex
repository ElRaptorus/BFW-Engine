defmodule BfwEngine.Execution.ProcessInstance.StandardMode do
  @moduledoc """
  Default execution mode for standard BPMN process instances.

  Implements `Mode` by delegating start-event resolution to
  `StartEventResolver` and using the standard "no active/waiting FNIs"
  completion check. This module produces identical behaviour to the
  pre-refactor hardcoded logic in `ProcessInstance`.
  """

  @behaviour BfwEngine.Execution.ProcessInstance.Mode

  alias BfwEngine.BPMN.Model.FlowNode
  alias BfwEngine.BPMN.Model.Process, as: BpmnProcess
  alias BfwEngine.Execution.ProcessInstance.StartEventResolver
  alias BfwEngine.Execution.ProcessInstance.State

  @impl true
  @spec resolve_initial_state(BpmnProcess.t(), String.t() | nil, String.t()) ::
          {:ok, FlowNode.t()} | {:error, atom(), String.t()}
  def resolve_initial_state(process_model, start_event_id, _process_id) do
    StartEventResolver.resolve(process_model, start_event_id)
  end

  @impl true
  @spec initial_dispatch(State.t(), FlowNode.t() | nil, map(), boolean()) :: State.t()
  def initial_dispatch(data, _start_node, _token, _esp_start_passthrough) do
    data
  end

  @impl true
  @spec should_complete?(State.t()) :: boolean()
  def should_complete?(data) do
    not Enum.any?(data.flow_node_instance_states, fn {_id, entry} ->
      entry.state in [:active, :waiting]
    end)
  end
end
