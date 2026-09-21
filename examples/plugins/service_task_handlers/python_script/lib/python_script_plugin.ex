defmodule Examples.ServiceTaskHandlers.PythonScript.PythonScriptFacadeStore do
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

defmodule Examples.ServiceTaskHandlers.PythonScript.PythonScriptPlugin do
  @moduledoc """
  Registers the async `"python_script"` Service Task handler.

  Copy into your OTP application and point `:plugin_module` at this module.
  Other-language **work** belongs on a Service Task (this plugin). For
  synchronous Script Tasks that exec local files, see
  `examples/plugins/named_scripts/local_script_runner/`.
  """

  @behaviour BfwEngine.Plugin

  @doc "Stores the facade for async completion and registers the python_script handler."
  @impl true
  def on_load(facade) do
    Examples.ServiceTaskHandlers.PythonScript.PythonScriptFacadeStore.put(facade)

    facade.register_service_task_handler.(
      "python_script",
      Examples.ServiceTaskHandlers.PythonScript.PythonScriptHandler
    )

    :ok
  end

  @doc "Performs no extra work once every plugin has finished loading."
  @impl true
  def on_ready(_facade), do: :ok
end
