defmodule BfwEngine.Api.TimerSchedules do
  @moduledoc """
  Timer schedule reads and updates.
  Callers use `BfwEngine.Api`.
  """

  alias BfwEngine.Api.Validation
  alias BfwEngine.Timers.StartEventManager

  @doc """
  List Timer Start Event schedules.

  Requires `deploy_bpmn`. Filter opts (`:process_version_id`, `:enabled`)
  are forwarded to `StartEventManager.list_schedules/1`.
  """
  @spec list_timer_schedules(struct(), keyword()) ::
          {:ok, [map()]} | {:error, :forbidden, %{required_claim: term()}}
  def list_timer_schedules(identity, opts \\ []) do
    {claim_opts, filter_opts} = Keyword.split(opts, [:skip_claims])

    with :ok <- Validation.check_claim(identity, "deploy_bpmn", claim_opts) do
      StartEventManager.list_schedules(filter_opts)
    end
  end

  @doc "Get a single Timer Start Event schedule by id."
  @spec get_timer_schedule(String.t(), struct(), keyword()) ::
          {:ok, map()} | {:error, :not_found} | BfwEngine.Api.forbidden_error()
  def get_timer_schedule(schedule_id, identity, opts \\ []) do
    with :ok <- Validation.check_claim(identity, "deploy_bpmn", opts) do
      StartEventManager.get_schedule(schedule_id)
    end
  end

  @doc "Re-enable a disabled cycle Timer Start Event schedule."
  @spec enable_timer_schedule(String.t(), struct(), keyword()) ::
          {:ok, map()} | {:error, term()} | BfwEngine.Api.forbidden_error()
  def enable_timer_schedule(schedule_id, identity, opts \\ []) do
    with :ok <- Validation.check_claim(identity, "deploy_bpmn", opts) do
      StartEventManager.enable_schedule(schedule_id)
    end
  end

  @doc "Disable an enabled cycle Timer Start Event schedule."
  @spec disable_timer_schedule(String.t(), struct(), keyword()) ::
          {:ok, map()} | {:error, term()} | BfwEngine.Api.forbidden_error()
  def disable_timer_schedule(schedule_id, identity, opts \\ []) do
    with :ok <- Validation.check_claim(identity, "deploy_bpmn", opts) do
      StartEventManager.disable_schedule(schedule_id)
    end
  end
end
