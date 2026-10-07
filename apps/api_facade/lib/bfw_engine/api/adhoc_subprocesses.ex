defmodule BfwEngine.Api.AdhocSubprocesses do
  @moduledoc """
  Ad-hoc subprocess control.
  Callers use `BfwEngine.Api`.
  """

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
    with :ok <- Validation.check_claim(identity, "manage_adhoc_subprocess", opts) do
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
    with :ok <- Validation.check_claim(identity, "manage_adhoc_subprocess", opts) do
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
    with :ok <- Validation.check_claim(identity, "manage_adhoc_subprocess", opts) do
      Execution.signal_adhoc_completion(process_instance_id)
    end
  end

  @doc """
  Get the runtime status of an ad-hoc subprocess.
  """
  @spec get_adhoc_status(String.t(), BfwEngine.Types.Identity.t(), keyword()) ::
          {:ok, map()} | {:error, term()} | BfwEngine.Api.forbidden_error()
  def get_adhoc_status(process_instance_id, identity, opts \\ []) do
    with :ok <- Validation.check_claim(identity, "manage_adhoc_subprocess", opts) do
      Execution.get_adhoc_status(process_instance_id)
    end
  end
end
