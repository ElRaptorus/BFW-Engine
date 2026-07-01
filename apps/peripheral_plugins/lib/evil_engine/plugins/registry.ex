defmodule EvilEngine.Plugins.Registry do
  @moduledoc """
  Central plugin registry.

  Maintains a map of `%{plugin_name => registration}` for every loaded
  plugin and its contributed capabilities (service-task handlers, event
  sinks, etc.).

  ## Conflict detection

  Each plugin capability has a conflict rule (see `EvilEngine.Plugin`):

  | Capability | Key | Rule |
  |------------|-----|------|
  | ServiceTaskHandler | `:implementation` | Unique (first wins, second quarantined) |
  | PersistenceAdapter | `:adapter_id` | Unique |
  | TimerSource | `:timer_type` | Unique per type |
  | DataStoreAdapter | `:store_id` | Unique per store-id |
  | NamedScript | `:script_key` | Unique by script-key |
  | EventSink | - | Many allowed |
  | MonitoringPanel | - | Many allowed |
  | RestApiExtension | `:prefix` | Unique per mount prefix |
  | AuthProvider | `:singleton` | Unique (first wins) |

  On conflict, the second registration is rejected and a
  `PluginQuarantined` event is emitted.
  """

  use GenServer

  alias EvilEngine.Events.EngineEventBus
  alias EvilEngine.Types.Event

  @capability_behaviours %{
    service_task_handler: EvilEngine.Plugin.ServiceTaskHandler,
    named_script: EvilEngine.Plugin.NamedScript,
    event_sink: EvilEngine.Plugin.EventSink,
    persistence_adapter: EvilEngine.Plugin.PersistenceAdapter,
    rest_api_extension: EvilEngine.Plugin.RestApiExtension,
    monitoring_panel: EvilEngine.Plugin.MonitoringPanel,
    timer_source: EvilEngine.Plugin.TimerSource,
    data_store_adapter: EvilEngine.Plugin.DataStoreAdapter,
    auth_provider: EvilEngine.Plugin.AuthProvider
  }

  defstruct plugins: %{}, capabilities: %{}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Register a plugin module with its manifest."
  @spec register_plugin(String.t(), module(), map()) :: :ok | {:error, term()}
  def register_plugin(name, module, manifest \\ %{}) do
    GenServer.call(__MODULE__, {:register_plugin, name, module, manifest})
  end

  @doc "Register a capability provided by a plugin."
  @spec register_capability(String.t(), atom(), map()) ::
          :ok
          | {:error, :conflict, String.t()}
          | {:error, :invalid_handler, String.t()}
          | {:error, :module_not_loaded, String.t()}
  def register_capability(plugin_name, capability_type, descriptor) do
    GenServer.call(__MODULE__, {:register_capability, plugin_name, capability_type, descriptor})
  end

  @doc "Get all registered plugins."
  @spec list_plugins() :: [map()]
  def list_plugins do
    GenServer.call(__MODULE__, :list_plugins)
  end

  @doc "Get all capabilities of a given type."
  @spec list_capabilities(atom()) :: [map()]
  def list_capabilities(capability_type) do
    GenServer.call(__MODULE__, {:list_capabilities, capability_type})
  end

  @doc "Get full registry state for diagnostics."
  @spec dump() :: map()
  def dump do
    GenServer.call(__MODULE__, :dump)
  end

  @doc "Remove all capabilities registered by a given plugin. Used for rollback on quarantine."
  @spec unregister_plugin_capabilities(String.t()) :: :ok
  def unregister_plugin_capabilities(plugin_name) do
    GenServer.call(__MODULE__, {:unregister_plugin_capabilities, plugin_name})
  end

  @doc false
  @spec reset_state() :: :ok
  def reset_state do
    GenServer.call(__MODULE__, :reset_state)
  end

  # --- Server callbacks ---------------------------------------------------

  @impl true
  def init(_opts) do
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_call({:register_plugin, name, module, manifest}, _from, state) do
    entry = %{
      name: name,
      module: module,
      manifest: manifest,
      status: :loaded,
      registered_at: DateTime.utc_now()
    }

    new_plugins = Map.put(state.plugins, name, entry)
    {:reply, :ok, %{state | plugins: new_plugins}}
  end

  @impl true
  def handle_call({:register_capability, plugin_name, cap_type, descriptor}, _from, state) do
    conflict_key = unique_key_for(cap_type, descriptor)

    existing =
      state.capabilities
      |> Map.get(cap_type, [])
      |> Enum.find(fn cap -> cap[:conflict_key] == conflict_key and conflict_key != nil end)

    if existing do
      emit_quarantine(plugin_name, cap_type, conflict_key, existing[:plugin_name])
      {:reply, {:error, :conflict, existing[:plugin_name]}, state}
    else
      case validate_handler_module(cap_type, descriptor) do
        :ok ->
          cap_entry = %{
            plugin_name: plugin_name,
            type: cap_type,
            descriptor: descriptor,
            conflict_key: conflict_key,
            registered_at: DateTime.utc_now()
          }

          caps = Map.get(state.capabilities, cap_type, [])
          new_caps = Map.put(state.capabilities, cap_type, caps ++ [cap_entry])
          {:reply, :ok, %{state | capabilities: new_caps}}

        {:error, reason, message} ->
          emit_validation_quarantine(plugin_name, cap_type, message)
          {:reply, {:error, reason, message}, state}
      end
    end
  end

  @impl true
  def handle_call(:list_plugins, _from, state) do
    result = state.plugins |> Map.values() |> Enum.sort_by(& &1.registered_at, DateTime)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:list_capabilities, cap_type}, _from, state) do
    result = Map.get(state.capabilities, cap_type, [])
    {:reply, result, state}
  end

  @impl true
  def handle_call(:dump, _from, state) do
    {:reply, %{plugins: state.plugins, capabilities: state.capabilities}, state}
  end

  @impl true
  def handle_call({:unregister_plugin_capabilities, plugin_name}, _from, state) do
    new_caps =
      Map.new(state.capabilities, fn {cap_type, entries} ->
        {cap_type, Enum.reject(entries, &(&1.plugin_name == plugin_name))}
      end)

    {:reply, :ok, %{state | capabilities: new_caps}}
  end

  @impl true
  def handle_call(:reset_state, _from, _state) do
    {:reply, :ok, %__MODULE__{}}
  end

  # --- Conflict detection helpers -----------------------------------------

  defp unique_key_for(:service_task_handler, %{implementation: key}), do: key
  defp unique_key_for(:persistence_adapter, %{adapter_id: key}), do: key
  defp unique_key_for(:timer_source, %{timer_type: key}), do: key
  defp unique_key_for(:data_store_adapter, %{store_id: key}), do: key
  defp unique_key_for(:named_script, %{script_key: key}), do: key
  defp unique_key_for(:rest_api_extension, %{prefix: key}), do: key
  defp unique_key_for(:auth_provider, _descriptor), do: :singleton
  defp unique_key_for(_cap_type, _descriptor), do: nil

  defp emit_quarantine(plugin_name, cap_type, conflict_key, incumbent) do
    reason =
      "Conflict on #{cap_type} key=#{inspect(conflict_key)}: " <>
        "#{plugin_name} rejected in favour of #{incumbent}"

    event =
      Event.PluginQuarantined.new(%{
        plugin_name: plugin_name,
        tier: :inbeam,
        reason: reason,
        occurred_at: DateTime.utc_now()
      })

    EngineEventBus.publish(event)
  rescue
    _ -> :ok
  end

  defp emit_validation_quarantine(plugin_name, cap_type, message) do
    reason = "Behaviour validation failed for #{cap_type}: #{message}"

    event =
      Event.PluginQuarantined.new(%{
        plugin_name: plugin_name,
        tier: :inbeam,
        reason: reason,
        occurred_at: DateTime.utc_now()
      })

    EngineEventBus.publish(event)
  rescue
    _ -> :ok
  end

  # --- Behaviour validation helpers ----------------------------------------

  defp validate_handler_module(cap_type, descriptor) do
    case {Map.get(@capability_behaviours, cap_type), Map.get(descriptor, :module)} do
      {nil, _} ->
        :ok

      {_behaviour, nil} ->
        :ok

      {behaviour, handler_module} when is_atom(handler_module) ->
        validate_module_implements(handler_module, behaviour)

      {_behaviour, _other} ->
        :ok
    end
  end

  defp validate_module_implements(handler_module, behaviour) do
    case Code.ensure_loaded(handler_module) do
      {:module, _} ->
        declared_behaviours =
          handler_module.__info__(:attributes)
          |> Keyword.get_values(:behaviour)
          |> List.flatten()

        if behaviour in declared_behaviours do
          :ok
        else
          {:error, :invalid_handler,
           "Module #{inspect(handler_module)} does not declare @behaviour #{inspect(behaviour)}"}
        end

      {:error, reason} ->
        {:error, :module_not_loaded,
         "Module #{inspect(handler_module)} could not be loaded: #{inspect(reason)}"}
    end
  end
end
