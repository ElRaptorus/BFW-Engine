defmodule BfwEngine.Plugins.Loader do
  @moduledoc """
  In-BEAM plugin lifecycle driver.

  Reads `BFE_PLUGINS_INBEAM` (`:engine_plugins, :inbeam_apps`),
  discovers `@behaviour BfwEngine.Plugin` modules via each OTP app's
  `:plugin_module` application env key, applies include/exclude filtering,
  and drives the `on_load/1` → `on_ready/1` lifecycle.

  Built-in capabilities (HTTP Service Task, etc.) are registered before
  user plugins so they can be overridden.
  """

  use GenServer

  require Logger

  alias BfwEngine.Events.EngineEventBus
  alias BfwEngine.Plugins.FacadeBuilder
  alias BfwEngine.Plugins.Registry
  alias BfwEngine.Types.Event

  @builtin_plugin_name "bfw:builtin"

  defstruct loaded_plugins: [], quarantined_plugins: []

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns the list of successfully loaded plugin entries."
  @spec loaded_plugins() :: [%{name: String.t(), module: module()}]
  def loaded_plugins do
    GenServer.call(__MODULE__, :loaded_plugins)
  end

  @doc "Returns the list of quarantined plugin entries."
  @spec quarantined_plugins() :: [map()]
  def quarantined_plugins do
    GenServer.call(__MODULE__, :quarantined_plugins)
  end

  # -------------------------------------------------------------------
  # Server callbacks
  # -------------------------------------------------------------------

  @impl true
  def init(_opts) do
    state = %__MODULE__{}

    register_builtin_capabilities()

    inbeam_apps = Application.get_env(:engine_plugins, :inbeam_apps, [])
    include_list = Application.get_env(:engine_plugins, :include_plugins, [])
    exclude_list = Application.get_env(:engine_plugins, :exclude_plugins, [])

    state = load_plugins(state, inbeam_apps, include_list, exclude_list)

    {:ok, state, {:continue, :on_ready}}
  end

  @impl true
  def handle_continue(:on_ready, state) do
    state = run_on_ready(state)
    {:noreply, state}
  end

  @impl true
  def handle_call(:loaded_plugins, _from, state) do
    {:reply, state.loaded_plugins, state}
  end

  @impl true
  def handle_call(:quarantined_plugins, _from, state) do
    {:reply, state.quarantined_plugins, state}
  end

  # -------------------------------------------------------------------
  # Built-in capability registration
  # -------------------------------------------------------------------

  @spec register_builtin_capabilities() :: :ok
  defp register_builtin_capabilities do
    _register = Registry.register_plugin(@builtin_plugin_name, __MODULE__, %{builtin: true})

    _register =
      Registry.register_capability(
        @builtin_plugin_name,
        :service_task_handler,
        %{implementation: "http", module: BfwEngine.Plugins.Builtin.HttpServiceTaskHandler}
      )

    :ok
  end

  # -------------------------------------------------------------------
  # Plugin discovery + on_load
  # -------------------------------------------------------------------

  defp load_plugins(state, inbeam_apps, include_list, exclude_list) do
    Enum.reduce(inbeam_apps, state, fn app_name, acc ->
      plugin_name = Atom.to_string(app_name)

      case check_include_exclude(plugin_name, include_list, exclude_list) do
        :ok ->
          discover_and_load(acc, app_name, plugin_name)

        {:skip, reason} ->
          Logger.info("Plugin #{plugin_name} skipped: #{reason}")
          acc

        {:quarantine, reason} ->
          quarantine(acc, plugin_name, reason)
      end
    end)
  end

  defp check_include_exclude(plugin_name, include_list, exclude_list) do
    in_include = plugin_name in include_list
    in_exclude = plugin_name in exclude_list

    cond do
      in_include and in_exclude ->
        {:quarantine, :ambiguous_policy}

      in_exclude ->
        {:skip, :excluded}

      include_list != [] and not in_include ->
        {:skip, :not_in_include_list}

      true ->
        :ok
    end
  end

  defp discover_and_load(state, app_name, plugin_name) do
    with :ok <- verify_app_loaded(app_name),
         {:ok, plugin_module} <- find_plugin_module(app_name),
         :ok <- verify_plugin_behaviour(plugin_module) do
      run_on_load(state, plugin_name, plugin_module)
    else
      {:error, reason} ->
        quarantine(state, plugin_name, reason)
    end
  end

  defp verify_app_loaded(app_name) do
    case Application.spec(app_name) do
      nil -> {:error, :app_not_loaded}
      _spec -> :ok
    end
  end

  defp find_plugin_module(app_name) do
    case Application.get_env(app_name, :plugin_module) do
      nil -> {:error, :missing_plugin_module}
      module when is_atom(module) -> {:ok, module}
    end
  end

  defp verify_plugin_behaviour(module) do
    case Code.ensure_loaded(module) do
      {:module, _} ->
        behaviours =
          module.__info__(:attributes)
          |> Keyword.get_values(:behaviour)
          |> List.flatten()

        if BfwEngine.Plugin in behaviours do
          :ok
        else
          {:error, :invalid_plugin_module}
        end

      {:error, _} ->
        {:error, :invalid_plugin_module}
    end
  end

  defp run_on_load(state, plugin_name, plugin_module) do
    facade = FacadeBuilder.build(plugin_name)

    case safe_on_load(plugin_module, facade) do
      :ok ->
        _register = Registry.register_plugin(plugin_name, plugin_module, %{})

        loaded_entry = %{name: plugin_name, module: plugin_module}
        %{state | loaded_plugins: state.loaded_plugins ++ [loaded_entry]}

      {:error, reason} ->
        quarantine(state, plugin_name, reason)
    end
  end

  defp safe_on_load(module, facade) do
    case module.on_load(facade) do
      :ok -> :ok
      {:error, reason} -> {:error, {:on_load_failed, reason}}
    end
  rescue
    exception ->
      {:error, {:on_load_crashed, exception}}
  end

  # -------------------------------------------------------------------
  # on_ready phase
  # -------------------------------------------------------------------

  defp run_on_ready(state) do
    Enum.reduce(state.loaded_plugins, state, fn plugin_entry, acc ->
      facade = FacadeBuilder.build(plugin_entry.name)

      case safe_on_ready(plugin_entry.module, facade) do
        :ok ->
          acc

        {:error, reason} ->
          Registry.unregister_plugin_capabilities(plugin_entry.name)
          acc = quarantine(acc, plugin_entry.name, reason)

          %{
            acc
            | loaded_plugins: Enum.reject(acc.loaded_plugins, &(&1.name == plugin_entry.name))
          }
      end
    end)
  end

  defp safe_on_ready(module, facade) do
    case module.on_ready(facade) do
      :ok -> :ok
      {:error, reason} -> {:error, {:on_ready_failed, reason}}
    end
  rescue
    exception ->
      {:error, {:on_ready_crashed, exception}}
  end

  # -------------------------------------------------------------------
  # Quarantine
  # -------------------------------------------------------------------

  defp quarantine(state, plugin_name, reason) do
    Logger.warning("Plugin #{plugin_name} quarantined: #{inspect(reason)}")

    entry = %{
      name: plugin_name,
      reason: reason,
      quarantined_at: DateTime.utc_now()
    }

    EngineEventBus.publish(
      Event.PluginQuarantined.new(%{
        plugin_name: plugin_name,
        tier: :inbeam,
        reason: reason,
        occurred_at: DateTime.utc_now()
      })
    )

    %{state | quarantined_plugins: state.quarantined_plugins ++ [entry]}
  end
end
