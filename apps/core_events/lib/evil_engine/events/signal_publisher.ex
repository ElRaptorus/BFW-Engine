defmodule EvilEngine.Events.SignalPublisher do
  @moduledoc """
  Orchestrates the signal broadcast algorithm.

  Full pipeline:

  1. Generate UUID signal ID
  2. Insert `signals` audit row (no payload, no correlation)
  3. ETS lookup for matching subscriptions (by signal_name only)
  4. Deliver `{:signal_arrived, signal_id}` to each subscription via `send(via_pid, ...)`
  5. Simultaneously call `SignalStartHandler` callback — start new PIs from Signal Start Events
  6. If zero deliveries AND zero start events fired → insert `pending_signals` with TTL
  7. Persist delivery list on audit row
  8. Emit `Event.SignalPublished` via EngineEventBus
  9. Return `{:ok, %PublishResult{}}`

  Key difference from messages: steps 4 and 5 both run regardless of
  each other's results. A signal always broadcasts to catch/boundary
  AND starts new PIs simultaneously (true broadcast, no gating).
  """

  alias EvilEngine.Events.EngineEventBus
  alias EvilEngine.Events.SignalPersistence
  alias EvilEngine.Events.SignalSubscriptions
  alias EvilEngine.Types.Event

  require Logger

  defmodule PublishResult do
    @moduledoc """
    Return value from `publish_signal/1`.

    - `deliveries` — list of `%{process_instance_id, flow_node_instance_id}` for
      each subscription that received the signal
    - `started_process_instance_ids` — IDs of new PIs started via Signal Start Events
    - `pending` — whether the signal was buffered as a pending signal
    """

    @type t :: %__MODULE__{
            signal_id: String.t(),
            signal_name: String.t(),
            deliveries: [%{process_instance_id: String.t(), flow_node_instance_id: String.t()}],
            started_process_instance_ids: [String.t()],
            pending: boolean()
          }

    defstruct signal_id: nil,
              signal_name: nil,
              deliveries: [],
              started_process_instance_ids: [],
              pending: false
  end

  @doc """
  Publish a signal via broadcast.

  ## Parameters

  - `params.name` — BPMN signal name (from `SignalDefinition.name`)
  - `params.origin` — `%{source: "pi" | "api" | "plugin", ...}` identifying the publisher
  - `params.skip_pending` — when `true`, never insert a pending signal row
    (used for REST/API debug triggers that should not be buffered)

  ## Returns

  `{:ok, %PublishResult{}}` on success.
  """
  @spec publish_signal(map()) :: {:ok, PublishResult.t()}
  def publish_signal(params) do
    signal_id = generate_signal_id()
    signal_name = params.name
    origin = params[:origin] || %{source: "unknown"}
    skip_pending = params[:skip_pending] || false
    now = DateTime.utc_now()
    triggerer_fni_id = origin[:flow_node_instance_id]

    persist_signal_audit(signal_id, signal_name, origin, now)

    subscriptions = SignalSubscriptions.lookup(signal_name)
    deliveries = deliver_to_subscriptions(subscriptions, signal_id, triggerer_fni_id)

    started_process_instance_ids = invoke_start_event_handler(signal_name, triggerer_fni_id)

    persist_started_process_instance_ids(signal_id, started_process_instance_ids)
    persist_delivery_records(signal_id, deliveries)

    has_recipients = deliveries != [] or started_process_instance_ids != []

    if has_recipients do
      cancel_orphan_pending_signals(signal_name)
    end

    pending =
      if not skip_pending and not has_recipients do
        insert_pending_signal(signal_id, signal_name, now)
        true
      else
        false
      end

    emit_signal_published(
      signal_id,
      signal_name,
      origin,
      deliveries,
      started_process_instance_ids,
      pending
    )

    :telemetry.execute(
      [:evil_engine, :signal, :published],
      %{delivery_count: length(deliveries)},
      %{signal_name: signal_name}
    )

    {:ok,
     %PublishResult{
       signal_id: signal_id,
       signal_name: signal_name,
       deliveries: deliveries,
       started_process_instance_ids: started_process_instance_ids,
       pending: pending
     }}
  end

  # -------------------------------------------------------------------
  # Private: audit persistence
  # -------------------------------------------------------------------

  defp persist_signal_audit(signal_id, signal_name, origin, now) do
    case SignalPersistence.adapter() do
      nil ->
        :ok

      adapter ->
        adapter.insert_signal(%{
          id: signal_id,
          signal_name: signal_name,
          origin: origin,
          published_at: now,
          deliveries: [],
          started_process_instance_ids: []
        })
    end
  rescue
    exception ->
      Logger.warning(
        "SignalPublisher: signal audit insert failed: #{Exception.message(exception)}"
      )
  end

  defp persist_started_process_instance_ids(_signal_id, []), do: :ok

  defp persist_started_process_instance_ids(signal_id, started_ids) do
    case SignalPersistence.adapter() do
      nil ->
        :ok

      adapter ->
        adapter.update_started_process_instance_ids(signal_id, started_ids)
    end
  rescue
    exception ->
      Logger.warning(
        "SignalPublisher: started PI IDs update failed: #{Exception.message(exception)}"
      )
  end

  defp persist_delivery_records(_signal_id, []), do: :ok

  defp persist_delivery_records(signal_id, deliveries) do
    case SignalPersistence.adapter() do
      nil ->
        :ok

      adapter ->
        Enum.each(deliveries, fn delivery ->
          adapter.append_signal_delivery(signal_id, %{
            process_instance_id: delivery.process_instance_id,
            flow_node_instance_id: delivery.flow_node_instance_id,
            delivered_at: DateTime.to_iso8601(DateTime.utc_now())
          })
        end)
    end
  rescue
    exception ->
      Logger.warning(
        "SignalPublisher: delivery record append failed: #{Exception.message(exception)}"
      )
  end

  defp insert_pending_signal(signal_id, signal_name, now) do
    case SignalPersistence.adapter() do
      nil ->
        :ok

      adapter ->
        ttl_iso = Application.get_env(:core_events, :signal_pending_ttl, "PT60S")
        ttl_seconds = parse_iso_duration_to_seconds(ttl_iso)
        expires_at = DateTime.add(now, ttl_seconds, :second)

        adapter.insert_pending_signal(%{
          signal_id: signal_id,
          signal_name: signal_name,
          published_at: now,
          expires_at: expires_at,
          state: "pending"
        })
    end
  rescue
    exception ->
      Logger.warning(
        "SignalPublisher: pending signal insert failed: #{Exception.message(exception)}"
      )
  end

  defp cancel_orphan_pending_signals(signal_name) do
    case SignalPersistence.adapter() do
      nil ->
        :ok

      adapter ->
        adapter.cancel_pending_for_signal_name(signal_name)
    end
  rescue
    exception ->
      Logger.warning(
        "SignalPublisher: cancel_orphan_pending_signals failed: #{Exception.message(exception)}"
      )
  end

  # -------------------------------------------------------------------
  # Private: delivery
  # -------------------------------------------------------------------

  defp deliver_to_subscriptions(subscriptions, signal_id, triggerer_fni_id) do
    Enum.map(subscriptions, fn subscription ->
      # ESP-D13c: signals are broadcast-all. An ESP signal start fires alongside
      # inline catches/boundaries and standalone starts. Its `via_pid` is the
      # scope PI, which routes `{:event_subprocess_signal, flow_node_id}` to
      # `trigger_event_subprocess/*`; all other kinds get the generic delivery.
      case subscription.kind do
        :event_subprocess_start ->
          send(subscription.via_pid, {:event_subprocess_signal, subscription.flow_node_id})

        _ ->
          send(subscription.via_pid, {:signal_arrived, signal_id, triggerer_fni_id})
      end

      EngineEventBus.publish(%Event.SignalArrived{
        signal_id: signal_id,
        signal_name: subscription.signal_name,
        process_instance_id: subscription.process_instance_id,
        flow_node_instance_id: subscription.flow_node_instance_id,
        lane_name: subscription.lane_name,
        occurred_at: DateTime.utc_now()
      })

      :telemetry.execute(
        [:evil_engine, :signal, :arrived],
        %{},
        %{
          signal_name: subscription.signal_name,
          process_instance_id: subscription.process_instance_id,
          flow_node_instance_id: subscription.flow_node_instance_id
        }
      )

      Logger.debug(
        "SignalPublisher: delivered signal=#{subscription.signal_name} " <>
          "to FNI=#{subscription.flow_node_instance_id} " <>
          "PI=#{subscription.process_instance_id}"
      )

      %{
        process_instance_id: subscription.process_instance_id,
        flow_node_instance_id: subscription.flow_node_instance_id
      }
    end)
  end

  # -------------------------------------------------------------------
  # Private: event emission
  # -------------------------------------------------------------------

  defp emit_signal_published(
         signal_id,
         signal_name,
         origin,
         deliveries,
         started_process_instance_ids,
         pending
       ) do
    EngineEventBus.publish(%Event.SignalPublished{
      signal_id: signal_id,
      signal_name: signal_name,
      origin: origin,
      deliveries: deliveries,
      started_process_instance_ids: started_process_instance_ids,
      pending: pending,
      occurred_at: DateTime.utc_now()
    })
  end

  # -------------------------------------------------------------------
  # Private: Signal Start Event discovery (true broadcast, no gating)
  # -------------------------------------------------------------------

  defp invoke_start_event_handler(signal_name, triggerer_fni_id) do
    case Application.get_env(:core_events, :signal_start_event_handler) do
      {module, function} ->
        case apply(module, function, [signal_name, triggerer_fni_id]) do
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
        "SignalPublisher: signal_start_event_handler failed: #{Exception.message(exception)}"
      )

      []
  end

  # -------------------------------------------------------------------
  # Private: helpers
  # -------------------------------------------------------------------

  defp generate_signal_id do
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
