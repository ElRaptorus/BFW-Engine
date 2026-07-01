defmodule Examples.ServiceTaskHandlers.RedisCache.RedisCacheConnection do
  @moduledoc """
  Agent that holds either a real Redix connection pid or an in-memory map used by
  the sample tests and local development.
  """

  use Agent

  @agent_name __MODULE__

  @doc "Starts the connection agent if it is not already registered under this module's name."
  @spec ensure_started() :: :ok
  def ensure_started do
    case Process.whereis(@agent_name) do
      nil ->
        {:ok, _pid} = start_link(%{key_value_entries: %{}})
        :ok

      _pid ->
        :ok
    end
  end

  defp start_link(initial_state) do
    Agent.start_link(fn -> initial_state end, name: @agent_name)
  end

  @doc "Simulates Redis GET, SET, or DEL against the in-memory stub when a real Redix connection is not used."
  @spec stub_command(list()) :: {:ok, term()} | {:error, term()}
  def stub_command(["GET", key]) when is_binary(key) do
    Agent.get(@agent_name, fn %{key_value_entries: entries} ->
      case Map.fetch(entries, key) do
        {:ok, value} -> {:ok, value}
        :error -> {:ok, nil}
      end
    end)
  end

  def stub_command(["SET", key, value]) when is_binary(key) do
    Agent.update(@agent_name, fn state ->
      %{state | key_value_entries: Map.put(state.key_value_entries, key, value)}
    end)

    {:ok, "OK"}
  end

  def stub_command(["DEL", key]) when is_binary(key) do
    deleted_count =
      Agent.get_and_update(@agent_name, fn %{key_value_entries: entries} = state ->
        if Map.has_key?(entries, key) do
          {1, %{state | key_value_entries: Map.delete(entries, key)}}
        else
          {0, state}
        end
      end)

    {:ok, deleted_count}
  end

  def stub_command(_other), do: {:error, :unsupported_redis_command}
end

defmodule Examples.ServiceTaskHandlers.RedisCache.RedisCacheFacadeStore do
  @moduledoc false
  use Agent

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> nil end, name: __MODULE__)
  end

  def put(facade) do
    ensure_started()
    Agent.update(__MODULE__, fn _ -> facade end)
  end

  def get do
    ensure_started()
    Agent.get(__MODULE__, & &1)
  end

  defp ensure_started do
    case Process.whereis(__MODULE__) do
      nil -> start_link()
      _pid -> :ok
    end
  end
end

defmodule Examples.ServiceTaskHandlers.RedisCache.RedisCachePlugin do
  @moduledoc """
  Registers the `"redis_cache"` handler (async) and starts the connection Agent.

  Replace `RedisCacheConnection.stub_command/1` with Redix in a real deployment.
  """

  @behaviour EvilEngine.Plugin

  @doc "Starts the stub Redis connection agent and registers the redis_cache Service Task handler."
  @impl true
  def on_load(facade) do
    :ok = Examples.ServiceTaskHandlers.RedisCache.RedisCacheConnection.ensure_started()
    Examples.ServiceTaskHandlers.RedisCache.RedisCacheFacadeStore.put(facade)

    facade.register_service_task_handler.(
      "redis_cache",
      Examples.ServiceTaskHandlers.RedisCache.RedisCacheHandler
    )

    :ok
  end

  @doc "Performs no extra work once every plugin has finished loading."
  @impl true
  def on_ready(_facade), do: :ok
end
