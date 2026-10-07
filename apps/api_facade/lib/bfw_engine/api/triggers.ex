defmodule BfwEngine.Api.Triggers do
  @moduledoc """
  Message, signal, timer, and escalation triggers.
  Callers use `BfwEngine.Api`.
  """

  alias BfwEngine.Api.ProcessInstances
  alias BfwEngine.Api.Validation
  alias BfwEngine.Events.MessagePublisher
  alias BfwEngine.Events.MessageSubscriptions
  alias BfwEngine.Events.SignalPublisher
  alias BfwEngine.Events.SignalSubscriptions
  alias BfwEngine.Execution

  @doc """
  Publish a message event.

  Validates `trigger_message` claim and subscription readiness before
  delegating to `MessagePublisher`.
  """
  @spec publish_message(String.t(), map(), String.t() | nil, struct(), keyword()) ::
          {:ok, map()} | {:error, :subscriptions_not_ready} | BfwEngine.Api.forbidden_error()
  def publish_message(message_name, payload, correlation, identity, opts \\ []) do
    with :ok <- check_message_subscriptions_ready(),
         :ok <- Validation.check_required_claim(identity, "trigger_message", "all", opts) do
      MessagePublisher.publish_message(%{
        name: message_name,
        payload: payload,
        correlation_value: correlation,
        origin: derive_origin(identity),
        skip_pending: Keyword.get(opts, :skip_pending, false)
      })
    end
  end

  @doc """
  Broadcast a signal event.

  Validates `trigger_signal` claim and subscription readiness before
  delegating to `SignalPublisher`.
  """
  @spec publish_signal(String.t(), struct(), keyword()) ::
          {:ok, map()} | {:error, :subscriptions_not_ready} | BfwEngine.Api.forbidden_error()
  def publish_signal(signal_name, identity, opts \\ []) do
    with :ok <- check_signal_subscriptions_ready(),
         :ok <- Validation.check_required_claim(identity, "trigger_signal", "all", opts) do
      SignalPublisher.publish_signal(%{
        name: signal_name,
        origin: derive_origin(identity),
        skip_pending: Keyword.get(opts, :skip_pending, false)
      })
    end
  end

  defp check_message_subscriptions_ready do
    if MessageSubscriptions.ready?(), do: :ok, else: {:error, :subscriptions_not_ready}
  end

  defp check_signal_subscriptions_ready do
    if SignalSubscriptions.ready?(), do: :ok, else: {:error, :subscriptions_not_ready}
  end

  # ===========================================================================
  # Runtime — Timer event manual trigger
  # ===========================================================================

  @doc """
  Manually trigger a waiting Timer Event FNI.

  Validates FNI existence, timer event type, active/waiting state,
  and lane access before delegating to Execution.
  """
  @spec trigger_timer_event(String.t(), struct(), keyword()) ::
          :ok | {:error, term()} | BfwEngine.Api.forbidden_error()
  def trigger_timer_event(flow_node_instance_id, identity, opts \\ []) do
    with {:ok, flow_node_instance} <-
           ProcessInstances.get_flow_node_instance(flow_node_instance_id),
         :ok <- validate_timer_event_type(flow_node_instance),
         :ok <- validate_fni_active_or_waiting(flow_node_instance),
         :ok <- Validation.check_lane_access(flow_node_instance, identity, opts) do
      Execution.trigger_timer_event(
        flow_node_instance.process_instance_id,
        flow_node_instance_id
      )
    end
  end

  @escalation_code_max_length 256

  @doc """
  Inject an escalation into waiting catchers on every running process instance.

  Validates the boolean `trigger_escalation` claim, then delegates to
  `Execution.trigger_escalation/2`. Escalations carry no payload.
  """
  @spec trigger_escalation(String.t(), struct(), keyword()) ::
          {:ok, map()}
          | {:error, :escalation_code_blank | :escalation_code_too_long}
          | BfwEngine.Api.forbidden_error()
  def trigger_escalation(escalation_code, identity, opts \\ []) do
    with {:ok, normalized_code} <- validate_escalation_code(escalation_code),
         :ok <- Validation.check_claim(identity, "trigger_escalation", opts) do
      {:ok, deliveries} = Execution.trigger_escalation(normalized_code, opts)

      {:ok,
       %{
         escalation_code: normalized_code,
         deliveries: deliveries,
         pending: false
       }}
    end
  end

  defp validate_escalation_code(escalation_code) when not is_binary(escalation_code) do
    {:error, :escalation_code_blank}
  end

  defp validate_escalation_code(escalation_code) do
    trimmed = String.trim(escalation_code)

    cond do
      trimmed == "" -> {:error, :escalation_code_blank}
      String.length(trimmed) > @escalation_code_max_length -> {:error, :escalation_code_too_long}
      true -> {:ok, trimmed}
    end
  end

  defp derive_origin(%{type: "plugin", plugin_name: plugin_name}),
    do: %{source: "plugin", plugin_name: plugin_name}

  defp derive_origin(identity),
    do: %{source: "api", triggered_by: identity.id}

  defp validate_fni_active_or_waiting(%{state: state}) when state in ["active", "waiting"],
    do: :ok

  defp validate_fni_active_or_waiting(%{state: "finished"}), do: {:error, :fni_already_finished}
  defp validate_fni_active_or_waiting(%{state: "aborted"}), do: {:error, :fni_already_aborted}

  defp validate_fni_active_or_waiting(%{state: "interrupted"}),
    do: {:error, :fni_already_interrupted}

  defp validate_fni_active_or_waiting(%{state: "fatal"}), do: {:error, :fni_already_fatal}
  defp validate_fni_active_or_waiting(_), do: {:error, :fni_not_active}

  defp validate_timer_event_type(%{flow_node_type: type, event_type: "timer"})
       when type in ["intermediate_catch_event", "boundary_event"] do
    :ok
  end

  defp validate_timer_event_type(_), do: {:error, :not_a_timer_event}
end
