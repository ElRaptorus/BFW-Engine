defmodule EvilEngine.Execution.ProcessInstance.CompensationOrchestrator do
  @moduledoc """
  Pure orchestrator for compensation runs.

  Given resolved compensation targets and a throw/end context, builds
  the execution plan (ordered queue of handler activities to dispatch).
  Does NOT spawn FNIs or dispatch — those remain in `ProcessInstance`.

  Sibling of `BoundaryOrchestrator` (which also explicitly documents
  "does not spawn FNIs — those remain in ProcessInstance").
  """

  @type compensation_target :: %{
          completed_fni_id: String.t(),
          flow_node_id: String.t(),
          handler_activity_id: String.t(),
          token_snapshot: map(),
          completion_order: non_neg_integer()
        }

  @type compensation_run :: %{
          queue: [compensation_target()],
          cursor: non_neg_integer(),
          mode: :broadcast | :single,
          throw_type: :throw | :end | :cancel,
          outgoing_flow_node_ids: [String.t()],
          token_payload: map()
        }

  @doc """
  Build a compensation run from resolved targets.

  Returns a `compensation_run` map ready to be stored in
  `data.compensation_runs[throw_fni_id]`.
  """
  @spec build_run(
          [compensation_target()],
          :throw | :end | :cancel,
          [String.t()],
          map()
        ) :: compensation_run()
  def build_run(targets, throw_type, outgoing_flow_node_ids, token_payload) do
    mode =
      case targets do
        [_single] -> :single
        _ -> :broadcast
      end

    %{
      queue: targets,
      cursor: 0,
      mode: mode,
      throw_type: throw_type,
      outgoing_flow_node_ids: outgoing_flow_node_ids,
      token_payload: token_payload
    }
  end

  @doc """
  Return the current target from the run, or `nil` if the run is complete.
  """
  @spec current_target(compensation_run()) :: compensation_target() | nil
  def current_target(%{queue: queue, cursor: cursor}) do
    Enum.at(queue, cursor)
  end

  @doc """
  Advance the cursor by one position. Returns the updated run.
  """
  @spec advance_cursor(compensation_run()) :: compensation_run()
  def advance_cursor(run) do
    %{run | cursor: run.cursor + 1}
  end

  @doc """
  Check whether the run has completed all targets.
  """
  @spec run_complete?(compensation_run()) :: boolean()
  def run_complete?(%{queue: queue, cursor: cursor}) do
    cursor >= length(queue)
  end
end
