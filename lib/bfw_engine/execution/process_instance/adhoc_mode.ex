defmodule BfwEngine.Execution.ProcessInstance.AdHocMode do
  @moduledoc """
  Execution mode for ad-hoc subprocess child PIs.

  An ad-hoc subprocess has no Start Event. Its inner activities are
  activated on demand — either by engine-managed logic or by a plugin
  — rather than by following sequence flows from a Start Event.

  - `resolve_initial_state/3` returns `{:ok, nil}` (no start event needed)
  - `initial_dispatch/4` is a no-op (PI starts idle, awaiting activation messages)
  - `should_complete?/1` returns `true` in two cases:
    1. `adhoc_completion_signaled` is set (FEEL condition fired or REST/plugin
       signal received) AND no FNI is `:active` or `:waiting`
    2. No FEEL completion condition is configured, at least one FNI has been
       dispatched, and no FNI is `:active` or `:waiting` (natural drain)
  """

  @behaviour BfwEngine.Execution.ProcessInstance.Mode

  alias BfwEngine.BPMN.Model.Process, as: BpmnProcess
  alias BfwEngine.Execution.ProcessInstance.State

  @impl true
  @spec resolve_initial_state(BpmnProcess.t(), String.t() | nil, String.t()) :: {:ok, nil}
  def resolve_initial_state(_process_model, _start_event_id, _process_id) do
    {:ok, nil}
  end

  @impl true
  @spec initial_dispatch(State.t(), nil, map(), boolean()) :: State.t()
  def initial_dispatch(data, _start_node, _token, _esp_start_passthrough) do
    data
  end

  @impl true
  @spec should_complete?(State.t()) :: boolean()
  def should_complete?(data) do
    no_active_fnis =
      not Enum.any?(data.flow_node_instance_states, fn {_id, entry} ->
        entry.state in [:active, :waiting]
      end)

    (data.adhoc_completion_signaled or data.adhoc_natural_drain_enabled) and no_active_fnis
  end
end
