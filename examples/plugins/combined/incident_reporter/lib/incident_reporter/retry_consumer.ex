defmodule IncidentReporter.RetryConsumer do
  @moduledoc """
  GenServer that subscribes to a message bus queue and processes incoming
  retry commands. Each command triggers a `facade.process_instances.retry`
  call through the engine facade.

  ## Retry Command Payload

  ```json
  {
    "type": "retryProcessInstance",
    "processInstanceId": "uuid",
    "version": "1.2.0",
    "resetToFlowNodeInstanceId": "uuid"
  }
  ```

  Only `type` and `processInstanceId` are required. `version` and
  `resetToFlowNodeInstanceId` are optional.

  ## Delivery Semantics

  The consumer acknowledges the bus message **after** the facade call
  returns, regardless of success or failure. This is at-most-once from
  the bus perspective. The engine's own idempotency guards (Registry
  check + DB state check) prevent double-retry if the same command
  arrives twice.
  """

  use GenServer

  require Logger

  @doc """
  Start the RetryConsumer.

  ## Options

    * `:engine_facade` — (required) the `EngineFacade` struct
    * `:message_bus_adapter` — (required) module implementing `MessageBus.Adapter`
    * `:connection` — (required) the bus connection handle
    * `:consume_queue` — (required) queue name to subscribe to
    * `:name` — (optional) registration name for the GenServer
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name, init_opts} = Keyword.pop(opts, :name)

    if name do
      GenServer.start_link(__MODULE__, init_opts, name: name)
    else
      GenServer.start_link(__MODULE__, init_opts)
    end
  end

  @impl true
  def init(opts) do
    engine_facade = Keyword.fetch!(opts, :engine_facade)
    adapter = Keyword.fetch!(opts, :message_bus_adapter)
    connection = Keyword.fetch!(opts, :connection)
    consume_queue = Keyword.fetch!(opts, :consume_queue)

    case adapter.subscribe(connection, consume_queue, self()) do
      :ok ->
        Logger.info("incident_reporter: retry consumer subscribed to queue #{consume_queue}")

        {:ok,
         %{
           engine_facade: engine_facade,
           message_bus_adapter: adapter,
           connection: connection,
           consume_queue: consume_queue,
           commands_processed: 0,
           commands_failed: 0
         }}

      {:error, reason} ->
        {:stop, {:subscribe_failed, reason}}
    end
  end

  @impl true
  def handle_info({:bus_message, payload}, state) when is_binary(payload) do
    case Jason.decode(payload) do
      {:ok, %{"type" => "retryProcessInstance", "processInstanceId" => process_instance_id} = command} ->
        handle_retry_command(process_instance_id, command, state)

      {:ok, %{"type" => unknown_type}} ->
        Logger.warning("incident_reporter: ignoring unknown command type: #{unknown_type}")
        {:noreply, state}

      {:ok, payload_without_type} ->
        Logger.warning(
          "incident_reporter: ignoring command without type field: #{inspect(payload_without_type)}"
        )

        {:noreply, state}

      {:error, decode_error} ->
        Logger.warning(
          "incident_reporter: failed to decode bus message: #{inspect(decode_error)}"
        )

        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp handle_retry_command(process_instance_id, command, state) do
    opts = build_retry_opts(command)

    case state.engine_facade.process_instances.retry.(process_instance_id, opts) do
      :ok ->
        Logger.info("incident_reporter: retried PI #{process_instance_id} via bus command")

        {:noreply,
         %{state | commands_processed: state.commands_processed + 1}}

      {:error, reason} ->
        Logger.warning(
          "incident_reporter: retry failed for PI #{process_instance_id}: #{inspect(reason)}"
        )

        {:noreply, %{state | commands_failed: state.commands_failed + 1}}

      {:error, code, detail} ->
        Logger.warning(
          "incident_reporter: retry failed for PI #{process_instance_id}: #{code} — #{inspect(detail)}"
        )

        {:noreply, %{state | commands_failed: state.commands_failed + 1}}
    end
  end

  defp build_retry_opts(command) do
    opts = %{}

    opts =
      case Map.get(command, "version") do
        nil -> opts
        version -> Map.put(opts, "version", version)
      end

    case Map.get(command, "resetToFlowNodeInstanceId") do
      nil -> opts
      fni_id -> Map.put(opts, "resetToFlowNodeInstanceId", fni_id)
    end
  end
end
