defmodule EvilEngine.Events.MessagePublisher do
  @moduledoc """
  Orchestrates the message publish algorithm.

  Full pipeline:

  1. Insert `messages` audit row (via persistence adapter)
  2. ETS lookup for matching subscriptions
  3. Deliver `MessageArrived` to each matching PI via `send(via_pid, {:message_arrived, ...})`
  4. Catch-wins-over-Start gating (Phase D — if no subscriptions, check for Message Start Events)
  5. Pending on zero-match (insert `pending_messages` row with TTL)
  6. Emit `Event.MessagePublished` via EngineEventBus
  7. Return `{:ok, %PublishResult{...}}`
  """

  alias EvilEngine.Events.EngineEventBus
  alias EvilEngine.Events.MessagePersistence
  alias EvilEngine.Events.MessageSubscriptions
  alias EvilEngine.Types.Event

  require Logger

  defmodule PublishResult do
    @moduledoc """
    Return value from `publish_message/1`.

    - `deliveries` — list of `%{process_instance_id, flow_node_instance_id}` for
      each subscription that received the message
    - `started_process_instance_ids` — IDs of new PIs started via Message Start Events
    - `pending` — whether the message was buffered as a pending message
    """

    @type t :: %__MODULE__{
            message_id: String.t(),
            message_name: String.t(),
            correlation_value: String.t() | nil,
            deliveries: [%{process_instance_id: String.t(), flow_node_instance_id: String.t()}],
            started_process_instance_ids: [String.t()],
            pending: boolean()
          }

    defstruct message_id: nil,
              message_name: nil,
              correlation_value: nil,
              deliveries: [],
              started_process_instance_ids: [],
              pending: false
  end

  @doc """
  Publish a message through the message correlation algorithm.

  ## Parameters

  - `params.name` — BPMN message name (from `MessageDefinition.name`)
  - `params.payload` — message payload (map)
  - `params.correlation_value` — resolved correlation value (string or nil)
  - `params.origin` — `%{source: "pi" | "api" | "plugin", ...}` identifying the publisher
  - `params.skip_pending` — when `true`, never insert a pending message row
    (used for REST/API debug triggers that should not be buffered)

  ## Returns

  `{:ok, %PublishResult{}}` on success.
  """
  @spec publish_message(map()) :: {:ok, PublishResult.t()}
  def publish_message(params) do
    message_id = generate_message_id()
    message_name = params.name
    correlation_value = params[:correlation_value]
    payload = params[:payload] || %{}
    origin = params[:origin] || %{source: "unknown"}
    skip_pending = params[:skip_pending] || false
    now = DateTime.utc_now()
    triggerer_fni_id = origin[:flow_node_instance_id]

    persist_message_audit(message_id, message_name, correlation_value, payload, origin, now)

    ets_correlation = correlation_value || :none
    all_subscriptions = MessageSubscriptions.lookup(message_name, ets_correlation)

    # ESP-D13: an Event Subprocess message start is a *gated* Start Event, not a
    # tier-1 delivery. Inline catch / boundary / receive-task subscriptions
    # (tier 1) always win; the ESP message start (tier 2) fires only when tier 1
    # delivered nothing, and it in turn suppresses standalone message starts
    # (tier 3, ESP-D13b).
    {event_subprocess_start_subscriptions, tier_one_subscriptions} =
      Enum.split_with(all_subscriptions, &(&1.kind == :event_subprocess_start))

    deliveries =
      deliver_to_subscriptions(tier_one_subscriptions, message_id, payload, triggerer_fni_id)

    event_subprocess_deliveries =
      if deliveries == [] do
        deliver_to_event_subprocess_starts(
          event_subprocess_start_subscriptions,
          message_id,
          payload
        )
      else
        []
      end

    combined_deliveries = deliveries ++ event_subprocess_deliveries

    persist_delivery_correlations(message_id, combined_deliveries)

    started_process_instance_ids =
      resolve_start_events(
        message_id,
        message_name,
        payload,
        ets_correlation,
        combined_deliveries,
        triggerer_fni_id
      )

    {pending, started_process_instance_ids} =
      resolve_pending(
        message_id,
        message_name,
        correlation_value,
        payload,
        now,
        combined_deliveries,
        started_process_instance_ids,
        skip_pending
      )

    emit_message_published(
      message_id,
      message_name,
      correlation_value,
      origin,
      combined_deliveries,
      started_process_instance_ids,
      pending
    )

    :telemetry.execute(
      [:evil_engine, :message, :published],
      %{delivery_count: length(combined_deliveries)},
      %{message_name: message_name, correlation_value: correlation_value}
    )

    {:ok,
     %PublishResult{
       message_id: message_id,
       message_name: message_name,
       correlation_value: correlation_value,
       deliveries: combined_deliveries,
       started_process_instance_ids: started_process_instance_ids,
       pending: pending
     }}
  end

  # -------------------------------------------------------------------
  # Private: audit persistence
  # -------------------------------------------------------------------

  defp persist_message_audit(message_id, message_name, correlation_value, payload, origin, now) do
    case MessagePersistence.adapter() do
      nil ->
        :ok

      adapter ->
        adapter.insert_message(%{
          id: message_id,
          message_name: message_name,
          payload: payload,
          correlation_value: correlation_value,
          origin: origin,
          published_at: now,
          correlations: []
        })
    end
  rescue
    exception ->
      Logger.warning(
        "MessagePublisher: message audit insert failed: #{Exception.message(exception)}"
      )
  end

  defp persist_delivery_correlations(_message_id, []), do: :ok

  defp persist_delivery_correlations(message_id, deliveries) do
    case MessagePersistence.adapter() do
      nil ->
        :ok

      adapter ->
        Enum.each(deliveries, fn delivery ->
          adapter.append_message_correlation(message_id, %{
            process_instance_id: delivery.process_instance_id,
            flow_node_instance_id: delivery.flow_node_instance_id,
            delivered_at: DateTime.utc_now() |> DateTime.to_iso8601()
          })
        end)
    end
  rescue
    exception ->
      Logger.warning(
        "MessagePublisher: correlation append failed: #{Exception.message(exception)}"
      )
  end

  defp persist_started_process_instance_ids(_message_id, []), do: :ok

  defp persist_started_process_instance_ids(message_id, started_ids) do
    case MessagePersistence.adapter() do
      nil -> :ok
      adapter -> adapter.update_started_process_instance_ids(message_id, started_ids)
    end
  rescue
    exception ->
      Logger.warning(
        "MessagePublisher: started_process_instance_ids persist failed: #{Exception.message(exception)}"
      )
  end

  defp insert_pending_message(message_id, message_name, correlation_value, payload, now) do
    case MessagePersistence.adapter() do
      nil ->
        :ok

      adapter ->
        ttl_iso = Application.get_env(:core_events, :message_pending_ttl, "PT60S")
        ttl_seconds = parse_iso_duration_to_seconds(ttl_iso)
        expires_at = DateTime.add(now, ttl_seconds, :second)

        adapter.insert_pending_message(%{
          message_id: message_id,
          message_name: message_name,
          correlation_value: correlation_value,
          payload: payload,
          published_at: now,
          expires_at: expires_at,
          state: "pending"
        })
    end
  rescue
    exception ->
      Logger.warning(
        "MessagePublisher: pending message insert failed: #{Exception.message(exception)}"
      )
  end

  defp resolve_start_events(
         message_id,
         message_name,
         payload,
         ets_correlation,
         deliveries,
         triggerer_fni_id
       ) do
    if deliveries == [] do
      started_ids =
        invoke_start_event_handler(message_name, payload, ets_correlation, triggerer_fni_id)

      persist_started_process_instance_ids(message_id, started_ids)
      started_ids
    else
      []
    end
  end

  defp resolve_pending(
         message_id,
         message_name,
         correlation_value,
         payload,
         now,
         deliveries,
         started_process_instance_ids,
         skip_pending
       ) do
    has_recipients = deliveries != [] or started_process_instance_ids != []

    if has_recipients do
      cancel_orphan_pending_messages(message_name, correlation_value)
    end

    pending =
      if not skip_pending and not has_recipients do
        insert_pending_message(message_id, message_name, correlation_value, payload, now)
        true
      else
        false
      end

    {pending, started_process_instance_ids}
  end

  defp cancel_orphan_pending_messages(message_name, correlation_value) do
    case MessagePersistence.adapter() do
      nil ->
        :ok

      adapter ->
        adapter.cancel_pending_for_message(message_name, correlation_value)
    end
  rescue
    exception ->
      Logger.warning(
        "MessagePublisher: cancel_orphan_pending_messages failed: #{Exception.message(exception)}"
      )
  end

  # -------------------------------------------------------------------
  # Private: delivery
  # -------------------------------------------------------------------

  defp deliver_to_subscriptions(subscriptions, message_id, payload, triggerer_fni_id) do
    Enum.map(subscriptions, fn subscription ->
      send(subscription.via_pid, {:message_arrived, message_id, payload, triggerer_fni_id})

      event_correlation =
        case subscription.expected_correlation_value do
          :none -> nil
          value -> value
        end

      EngineEventBus.publish(%Event.MessageArrived{
        message_id: message_id,
        message_name: subscription.message_name,
        correlation_value: event_correlation,
        process_instance_id: subscription.process_instance_id,
        flow_node_instance_id: subscription.flow_node_instance_id,
        payload: payload,
        lane_name: subscription.lane_name,
        root_process_instance_id: subscription.root_process_instance_id,
        occurred_at: DateTime.utc_now()
      })

      :telemetry.execute(
        [:evil_engine, :message, :arrived],
        %{},
        %{
          message_name: subscription.message_name,
          process_instance_id: subscription.process_instance_id,
          flow_node_instance_id: subscription.flow_node_instance_id
        }
      )

      Logger.debug(
        "MessagePublisher: delivered message=#{subscription.message_name} " <>
          "to FNI=#{subscription.flow_node_instance_id} " <>
          "PI=#{subscription.process_instance_id}"
      )

      %{
        process_instance_id: subscription.process_instance_id,
        flow_node_instance_id: subscription.flow_node_instance_id
      }
    end)
  end

  # ESP-D13: deliver a message to Event Subprocess message-start triggers. The
  # subscription's `via_pid` is the scope PI (not a handler Task); the PI routes
  # `{:event_subprocess_message, flow_node_id, payload}` to
  # `trigger_event_subprocess/*`. These count as deliveries (tier 2) so a
  # standalone message start (tier 3) is suppressed (ESP-D13b).
  defp deliver_to_event_subprocess_starts(subscriptions, message_id, payload) do
    Enum.map(subscriptions, fn subscription ->
      send(subscription.via_pid, {:event_subprocess_message, subscription.flow_node_id, payload})

      event_correlation =
        case subscription.expected_correlation_value do
          :none -> nil
          value -> value
        end

      EngineEventBus.publish(%Event.MessageArrived{
        message_id: message_id,
        message_name: subscription.message_name,
        correlation_value: event_correlation,
        process_instance_id: subscription.process_instance_id,
        flow_node_instance_id: subscription.flow_node_instance_id,
        payload: payload,
        lane_name: subscription.lane_name,
        root_process_instance_id: subscription.root_process_instance_id,
        occurred_at: DateTime.utc_now()
      })

      %{
        process_instance_id: subscription.process_instance_id,
        flow_node_instance_id: subscription.flow_node_instance_id
      }
    end)
  end

  # -------------------------------------------------------------------
  # Private: event emission
  # -------------------------------------------------------------------

  defp emit_message_published(
         message_id,
         message_name,
         correlation_value,
         origin,
         deliveries,
         started_process_instance_ids,
         pending
       ) do
    EngineEventBus.publish(%Event.MessagePublished{
      message_id: message_id,
      message_name: message_name,
      correlation_value: correlation_value,
      origin: origin,
      deliveries: deliveries,
      started_process_instance_ids: started_process_instance_ids,
      pending: pending,
      occurred_at: DateTime.utc_now()
    })
  end

  # -------------------------------------------------------------------
  # Private: Message Start Event discovery (catch-wins-over-start)
  # -------------------------------------------------------------------

  defp invoke_start_event_handler(message_name, payload, _ets_correlation, triggerer_fni_id) do
    case Application.get_env(:core_events, :message_start_event_handler) do
      {module, function} ->
        case apply(module, function, [message_name, payload, triggerer_fni_id]) do
          {:ok, started_ids} when is_list(started_ids) ->
            started_ids

          _ ->
            []
        end

      nil ->
        []
    end
  rescue
    exception ->
      Logger.warning(
        "MessagePublisher: message_start_event_handler failed: #{Exception.message(exception)}"
      )

      []
  end

  # -------------------------------------------------------------------
  # Private: helpers
  # -------------------------------------------------------------------

  defp generate_message_id do
    now_ms = System.os_time(:millisecond)
    <<rand_a::12, rand_b::62, _::6>> = :crypto.strong_rand_bytes(10)

    <<now_ms::48, 7::4, rand_a::12, 2::2, rand_b::62>>
    |> Base.encode16(case: :lower)
    |> then(fn hex ->
      <<a::binary-size(8), b::binary-size(4), c::binary-size(4), d::binary-size(4),
        e::binary-size(12)>> = hex

      "#{a}-#{b}-#{c}-#{d}-#{e}"
    end)
  end

  defp parse_iso_duration_to_seconds("PT" <> rest) do
    cond do
      String.ends_with?(rest, "S") ->
        rest |> String.trim_trailing("S") |> String.to_integer()

      String.ends_with?(rest, "M") ->
        minutes = rest |> String.trim_trailing("M") |> String.to_integer()
        minutes * 60

      String.ends_with?(rest, "H") ->
        hours = rest |> String.trim_trailing("H") |> String.to_integer()
        hours * 3600

      true ->
        60
    end
  end

  defp parse_iso_duration_to_seconds(_), do: 60
end
