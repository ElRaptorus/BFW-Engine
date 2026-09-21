defmodule BfwEngine.Execution.ProcessInstance.Facade do
  @moduledoc """
  The typed API that FNIs use to talk to their parent PI.

  Every FNI receives the PI's `pid` and interacts with it exclusively
  through this module. This decouples handler implementations from
  the PI's internal `:gen_statem` protocol.

  Phase 1 exposes a minimal subset. Additional functions (write_result,
  publish_message, evaluate_expression) will land as needed.
  """

  alias BfwEngine.Execution.ProcessInstance

  @doc "Complete a waiting User Task / Manual Task."
  @spec finish_user_task(pid(), String.t(), term(), BfwEngine.Types.Identity.t()) ::
          :ok | {:error, term()}
  def finish_user_task(process_instance_pid, flow_node_instance_id, result, identity) do
    ProcessInstance.finish_user_task(
      process_instance_pid,
      flow_node_instance_id,
      result,
      identity
    )
  end

  @doc "Cancel a waiting User Task."
  @spec cancel_user_task(pid(), String.t(), String.t() | nil, BfwEngine.Types.Identity.t()) ::
          :ok | {:error, term()}
  def cancel_user_task(process_instance_pid, flow_node_instance_id, reason, identity) do
    ProcessInstance.cancel_user_task(
      process_instance_pid,
      flow_node_instance_id,
      reason,
      identity
    )
  end
end
