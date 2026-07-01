defmodule Examples.ServiceTaskHandlers.RedisCache.RedisCacheHandler do
  @moduledoc """
  Reads cache directives from `token.payload` and issues Redis commands through
  `RedisCacheConnection` (stubbed with an Agent-backed map in this example).

  ## Async contract

  Redis is an external system — even though calls are typically fast, the
  connection can be down, slow, or partitioned. The handler spawns a Task
  for the Redis operation and completes the FNI through the facade.
  """

  @behaviour EvilEngine.Plugin.ServiceTaskHandler

  alias Examples.ServiceTaskHandlers.RedisCache.RedisCacheConnection

  @doc "Validates the operation, then spawns async Redis command execution."
  @impl true
  def handle_enter(_flow_node, token, handler_context) do
    flow_node_instance_id = handler_context.flow_node_instance_id
    facade = Examples.ServiceTaskHandlers.RedisCache.RedisCacheFacadeStore.get()

    case validate_operation(token.payload) do
      {:ok, operation_params} ->
        Task.start(fn ->
          execute_and_complete(operation_params, facade, flow_node_instance_id)
        end)

        {:async, flow_node_instance_id}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_operation(%{"operation" => "get", "key" => key}) when is_binary(key),
    do: {:ok, {:get, key}}

  defp validate_operation(%{"operation" => "set", "key" => key, "value" => value}) when is_binary(key),
    do: {:ok, {:set, key, value}}

  defp validate_operation(%{"operation" => "delete", "key" => key}) when is_binary(key),
    do: {:ok, {:delete, key}}

  defp validate_operation(_), do: {:error, :unknown_cache_operation}

  defp execute_and_complete({:get, key}, facade, flow_node_instance_id) do
    {:ok, value} = redis_command(["GET", key])

    facade.service_tasks.finish_async.(flow_node_instance_id, %{
      "operation" => "get",
      "key" => key,
      "value" => value
    })
  end

  defp execute_and_complete({:set, key, value}, facade, flow_node_instance_id) do
    {:ok, redis_status} = redis_command(["SET", key, value])

    facade.service_tasks.finish_async.(flow_node_instance_id, %{
      "operation" => "set",
      "key" => key,
      "redis_status" => redis_status
    })
  end

  defp execute_and_complete({:delete, key}, facade, flow_node_instance_id) do
    {:ok, deleted_count} = redis_command(["DEL", key])

    facade.service_tasks.finish_async.(flow_node_instance_id, %{
      "operation" => "delete",
      "key" => key,
      "deleted_count" => deleted_count
    })
  end

  defp redis_command(command_parts) do
    RedisCacheConnection.stub_command(command_parts)
  end
end
