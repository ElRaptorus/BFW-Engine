defmodule Examples.ServiceTaskHandlers.Echo.EchoFacadeStore do
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

defmodule Examples.ServiceTaskHandlers.Echo.EchoPlugin do
  @moduledoc """
  Registers the async `"echo"` Service Task handler.

  Copy into your OTP application and point `:plugin_module` at this module.
  """

  @behaviour EvilEngine.Plugin

  @doc "Stores the facade for async completion and registers the echo handler."
  @impl true
  def on_load(facade) do
    Examples.ServiceTaskHandlers.Echo.EchoFacadeStore.put(facade)
    facade.register_service_task_handler.("echo", Examples.ServiceTaskHandlers.Echo.EchoHandler)
    :ok
  end

  @doc "Performs no extra work once every plugin has finished loading."
  @impl true
  def on_ready(_facade), do: :ok
end
