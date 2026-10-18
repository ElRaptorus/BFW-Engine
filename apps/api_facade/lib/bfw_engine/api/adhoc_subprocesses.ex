defmodule BfwEngine.Api.AdhocSubprocesses do
  @moduledoc """
  Ad-hoc subprocess control.
  Callers use `BfwEngine.Api`.

  Every operation requires the `manage_adhoc_subprocess` claim and a visible
  child process instance (starter, lane access, `observe_all`, or the admin
  override). An invisible instance answers `{:error, :not_found}`.
  """

  alias BfwEngine.Api.ProcessInstances
  alias BfwEngine.Api.Validation
  alias BfwEngine.Execution

  @doc """
  Get the enabled/performed inner activities of an ad-hoc subprocess.

  `process_instance_id` is the **child** PI spawned by the ad-hoc subprocess
  handler — not the parent PI.
  """
  @spec get_adhoc_enabled_activities(String.t(), BfwEngine.Types.Identity.t(), keyword()) ::
          {:ok, [map()]} | {:error, term()} | BfwEngine.Api.forbidden_error()
  def get_adhoc_enabled_activities(process_instance_id, identity, opts \\ []) do
    with :ok <- Validation.check_claim(identity, "manage_adhoc_subprocess", opts),
         :ok <- check_visible(process_instance_id, identity, opts) do
      Execution.get_adhoc_enabled_activities(process_instance_id)
    end
  end

  @doc """
  Activate an inner activity within a running ad-hoc subprocess.

  `process_instance_id` is the child PI, `flow_node_id` is the BPMN element
  ID of the inner activity to activate.
  """
  @spec activate_adhoc_activity(String.t(), String.t(), BfwEngine.Types.Identity.t(), keyword()) ::
          {:ok, map()} | {:error, term()} | BfwEngine.Api.forbidden_error()
  def activate_adhoc_activity(process_instance_id, flow_node_id, identity, opts \\ []) do
    with :ok <- Validation.check_claim(identity, "manage_adhoc_subprocess", opts),
         :ok <- check_visible(process_instance_id, identity, opts) do
      Execution.activate_adhoc_activity(process_instance_id, flow_node_id)
    end
  end

  @doc """
  Signal the completion of an ad-hoc subprocess.

  The child PI will finish once all active/waiting FNIs complete.
  """
  @spec complete_adhoc_subprocess(String.t(), BfwEngine.Types.Identity.t(), keyword()) ::
          :ok | {:error, term()} | BfwEngine.Api.forbidden_error()
  def complete_adhoc_subprocess(process_instance_id, identity, opts \\ []) do
    with :ok <- Validation.check_claim(identity, "manage_adhoc_subprocess", opts),
         :ok <- check_visible(process_instance_id, identity, opts) do
      Execution.signal_adhoc_completion(process_instance_id)
    end
  end

  @doc """
  Get the runtime status of an ad-hoc subprocess.
  """
  @spec get_adhoc_status(String.t(), BfwEngine.Types.Identity.t(), keyword()) ::
          {:ok, map()} | {:error, term()} | BfwEngine.Api.forbidden_error()
  def get_adhoc_status(process_instance_id, identity, opts \\ []) do
    with :ok <- Validation.check_claim(identity, "manage_adhoc_subprocess", opts),
         :ok <- check_visible(process_instance_id, identity, opts) do
      Execution.get_adhoc_status(process_instance_id)
    end
  end

  defp check_visible(process_instance_id, identity, opts) do
    cond do
      Keyword.get(opts, :skip_claims, false) -> :ok
      Validation.admin_override?(identity) -> :ok
      Validation.observe_all?(identity) -> :ok
      true -> check_starter_or_lane(process_instance_id, identity)
    end
  end

  defp check_starter_or_lane(process_instance_id, identity) do
    with {:ok, process_instance} <- ProcessInstances.get_process_instance(process_instance_id) do
      starter? = get_in(process_instance.started_by, ["id"]) == identity.id

      if starter? or
           ProcessInstances.check_lane_access(
             process_instance_id,
             Validation.accessible_lanes(identity)
           ) do
        :ok
      else
        {:error, :not_found}
      end
    end
  end
end
