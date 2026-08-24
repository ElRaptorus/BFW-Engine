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
  | NamedScript | `:script_key` | Unique by script-key |
  | EventSink | - | Many allowed |
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
    rest_api_extension: EvilEngine.Plugin.RestApiExtension,
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
          | {:error, :reserved_prefix}
  def register_capability(plugin_name, capability_type, descriptor) do
    GenServer.call(__MODULE__, {:register_capability, plugin_name, capability_type, descriptor})
  end

  @doc """
  Longest-prefix match of a request path against registered REST API extensions.

  Returns `:error` when no extension prefix matches at a path-segment boundary.
  """
  @spec lookup_rest_api_extension(String.t()) ::
          {:ok, %{prefix: String.t(), module: module(), plugin_name: String.t()}} | :error
  def lookup_rest_api_extension(request_path) do
    GenServer.call(__MODULE__, {:lookup_rest_api_extension, request_path})
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
    descriptor = maybe_normalize_rest_api_prefix(cap_type, descriptor)

    case reserved_rest_api_prefix_error(cap_type, descriptor) do
      {:error, :reserved_prefix} = error ->
        {:reply, error, state}

      :ok ->
        conflict_key = unique_key_for(cap_type, descriptor)

        existing =
          state.capabilities
          |> Map.get(cap_type, [])
          |> Enum.find(fn cap -> cap[:conflict_key] == conflict_key and conflict_key != nil end)

        if existing do
          emit_quarantine(plugin_name, cap_type, conflict_key, existing[:plugin_name])
          {:reply, {:error, :conflict, existing[:plugin_name]}, state}
        else
          append_capability(state, plugin_name, cap_type, descriptor, conflict_key)
        end
    end
  end

  @impl true
  def handle_call({:lookup_rest_api_extension, request_path}, _from, state) do
    {:reply, do_lookup_rest_api_extension(state, request_path), state}
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

  defp append_capability(state, plugin_name, cap_type, descriptor, conflict_key) do
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

  # --- Conflict detection helpers -----------------------------------------

  defp unique_key_for(:service_task_handler, %{implementation: key}), do: key
  defp unique_key_for(:named_script, %{script_key: key}), do: key
  defp unique_key_for(:rest_api_extension, %{prefix: key}), do: key
  defp unique_key_for(:auth_provider, _descriptor), do: :singleton
  defp unique_key_for(_cap_type, _descriptor), do: nil

  @reserved_route_prefixes MapSet.new([
                             "/processes",
                             "/decisions",
                             "/process-instances",
                             "/user-tasks",
                             "/timer-schedules",
                             "/timer-events",
                             "/messages",
                             "/signals",
                             "/escalations",
                             "/adhoc-subprocesses",
                             "/stats",
                             "/api",
                             "/admin",
                             "/health",
                             "/info",
                             "/metrics"
                           ])

  defp maybe_normalize_rest_api_prefix(:rest_api_extension, %{prefix: prefix} = descriptor)
       when is_binary(prefix) do
    Map.put(descriptor, :prefix, normalize_route_prefix(prefix))
  end

  defp maybe_normalize_rest_api_prefix(_capability_type, descriptor), do: descriptor

  defp reserved_rest_api_prefix_error(:rest_api_extension, %{prefix: prefix})
       when is_binary(prefix) do
    if reserved_route_prefix?(prefix) do
      {:error, :reserved_prefix}
    else
      :ok
    end
  end

  defp reserved_rest_api_prefix_error(_capability_type, _descriptor), do: :ok

  defp reserved_route_prefix?(prefix) do
    normalized = normalize_route_prefix(prefix)

    Enum.any?(@reserved_route_prefixes, fn reserved ->
      normalized == reserved or String.starts_with?(normalized, reserved <> "/")
    end)
  end

  defp normalize_route_prefix(prefix) when is_binary(prefix) do
    trimmed = String.trim(prefix)

    with_leading_slash =
      if String.starts_with?(trimmed, "/"), do: trimmed, else: "/" <> trimmed

    String.trim_trailing(with_leading_slash, "/")
  end

  defp do_lookup_rest_api_extension(state, request_path) when is_binary(request_path) do
    normalized_path = normalize_route_prefix(request_path)

    state.capabilities
    |> Map.get(:rest_api_extension, [])
    |> Enum.filter(fn capability ->
      prefix = capability.descriptor[:prefix]
      is_binary(prefix) and path_matches_prefix?(normalized_path, prefix)
    end)
    |> Enum.max_by(
      fn capability -> String.length(capability.descriptor.prefix) end,
      fn -> nil end
    )
    |> case do
      nil ->
        :error

      capability ->
        {:ok,
         %{
           prefix: capability.descriptor.prefix,
           module: capability.descriptor[:module],
           plugin_name: capability.plugin_name
         }}
    end
  end

  defp path_matches_prefix?(request_path, prefix) do
    request_path == prefix or String.starts_with?(request_path, prefix <> "/")
  end

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
