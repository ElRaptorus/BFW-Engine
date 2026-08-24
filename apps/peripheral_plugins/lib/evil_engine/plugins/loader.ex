defmodule EvilEngine.Plugins.Loader do
  @moduledoc """
  In-BEAM plugin lifecycle driver.

  Reads `EVIL_PLUGINS_INBEAM` (`:peripheral_plugins, :inbeam_apps`),
  discovers `@behaviour EvilEngine.Plugin` modules via each OTP app's
  `:plugin_module` application env key, applies include/exclude filtering,
  and drives the `on_load/1` → `on_ready/1` lifecycle.

  Built-in capabilities (HTTP Service Task, etc.) are registered before
  user plugins so they can be overridden.
  """

  use GenServer

  require Logger

  alias EvilEngine.EngineFacade
  alias EvilEngine.Events.EngineEventBus
  alias EvilEngine.Plugins.Registry
  alias EvilEngine.Types.Event
  alias EvilEngine.Types.Identity

  @builtin_plugin_name "evil:builtin"

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

  @doc false
  @spec facade_for_plugin(String.t()) :: EngineFacade.t()
  def facade_for_plugin(plugin_name) when is_binary(plugin_name), do: build_facade(plugin_name)

  # -------------------------------------------------------------------
  # Server callbacks
  # -------------------------------------------------------------------

  @impl true
  def init(_opts) do
    state = %__MODULE__{}

    register_builtin_capabilities()

    inbeam_apps = Application.get_env(:peripheral_plugins, :inbeam_apps, [])
    include_list = Application.get_env(:peripheral_plugins, :include_plugins, [])
    exclude_list = Application.get_env(:peripheral_plugins, :exclude_plugins, [])

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

  @doc false
  @spec register_builtin_capabilities() :: :ok
  def register_builtin_capabilities do
    _register = Registry.register_plugin(@builtin_plugin_name, __MODULE__, %{builtin: true})

    _register =
      Registry.register_capability(
        @builtin_plugin_name,
        :service_task_handler,
        %{implementation: "http", module: EvilEngine.Plugins.Builtin.HttpServiceTaskHandler}
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

        if EvilEngine.Plugin in behaviours do
          :ok
        else
          {:error, :invalid_plugin_module}
        end

      {:error, _} ->
        {:error, :invalid_plugin_module}
    end
  end

  defp run_on_load(state, plugin_name, plugin_module) do
    facade = build_facade(plugin_name)

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
      facade = build_facade(plugin_entry.name)

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

  # -------------------------------------------------------------------
  # EngineFacade construction
  # -------------------------------------------------------------------

  defp build_facade(plugin_name) do
    identity = plugin_identity(plugin_name)

    %EngineFacade{
      engine_id: engine_id(),
      engine_name: engine_name(),
      version: engine_version(),
      register_service_task_handler: fn implementation, handler ->
        do_register(plugin_name, :service_task_handler, %{
          implementation: implementation,
          module: handler
        })
      end,
      register_named_script: fn script_key, handler ->
        do_register(plugin_name, :named_script, %{script_key: script_key, module: handler})
      end,
      register_persistence_adapter: fn adapter_id, handler ->
        do_register(plugin_name, :persistence_adapter, %{adapter_id: adapter_id, module: handler})
      end,
      register_rest_api_extension: fn prefix, handler ->
        do_register(plugin_name, :rest_api_extension, %{prefix: prefix, module: handler})
      end,
      register_monitoring_panel: fn handler ->
        do_register(plugin_name, :monitoring_panel, %{module: handler})
      end,
      register_timer_source: fn timer_type, handler ->
        do_register(plugin_name, :timer_source, %{timer_type: timer_type, module: handler})
      end,
      register_data_store_adapter: fn store_id, handler ->
        do_register(plugin_name, :data_store_adapter, %{store_id: store_id, module: handler})
      end,
      register_auth_provider: fn handler ->
        case do_register(plugin_name, :auth_provider, %{module: handler}) do
          :ok ->
            auth_registry = Application.get_env(:peripheral_plugins, :auth_provider_registry)

            if auth_registry do
              auth_registry.register_provider(handler)
            else
              :ok
            end

          error ->
            error
        end
      end,
      publish_event: &EngineEventBus.publish/1,
      register_event_sink: &EngineEventBus.register_sink/3,
      get_config: &Application.get_env(:peripheral_plugins, &1),
      processes: build_processes_namespace(identity),
      process_instances: build_process_instances_namespace(identity),
      user_tasks: build_user_tasks_namespace(),
      service_tasks: build_service_tasks_namespace(),
      flow_node_instances: build_flow_node_instances_namespace(),
      data_objects: build_data_objects_namespace(),
      decisions: build_decisions_namespace(identity, plugin_name),
      messages: build_messages_namespace(plugin_name),
      signals: build_signals_namespace(plugin_name),
      adhoc_subprocesses: build_adhoc_subprocesses_namespace(identity),
      timers: build_timers_namespace(identity),
      graphql: build_graphql_namespace(identity)
    }
  end

  defp plugin_identity(plugin_name) do
    %Identity{
      id: "plugin:#{plugin_name}",
      roles: [],
      groups: [],
      claims: %{}
    }
  end

  defp build_processes_namespace(identity) do
    plugin_source = "plugin:#{identity.id |> String.replace_leading("plugin:", "")}"

    %EngineFacade.Processes{
      list: fn -> EvilEngine.Api.list_processes() end,
      get: &EvilEngine.Api.get_process_by_model_id/1,
      get_latest_version: &resolve_latest_version/1,
      deploy: fn sources ->
        EvilEngine.Api.persist_deploy_batch(
          sources,
          identity,
          source: plugin_source,
          skip_claims: true
        )
      end,
      enable: fn model_id ->
        with_process(
          model_id,
          &EvilEngine.Api.update_process_enabled(&1, true,
            identity: identity,
            source: plugin_source,
            skip_claims: true
          )
        )
      end,
      disable: fn model_id ->
        with_process(
          model_id,
          &EvilEngine.Api.update_process_enabled(&1, false,
            identity: identity,
            source: plugin_source,
            skip_claims: true
          )
        )
      end,
      delete_version: fn model_id, vsn ->
        do_delete_version(model_id, vsn, identity, plugin_source)
      end,
      undeploy: fn model_id ->
        EvilEngine.Api.undeploy_process(model_id, identity,
          skip_claims: true,
          source: plugin_source
        )
      end,
      start: fn start_opts ->
        EvilEngine.Api.start_process_instance(start_opts, identity, skip_claims: true)
      end
    }
  end

  defp resolve_latest_version(process_model_id) do
    with_process(process_model_id, fn process ->
      EvilEngine.Api.get_latest_process_version(process.id)
    end)
  end

  defp do_delete_version(process_model_id, version_string, identity, source) do
    EvilEngine.Api.delete_process_version(
      process_model_id,
      version_string,
      identity,
      skip_claims: true,
      source: source
    )
  end

  defp with_process(process_model_id, fun) do
    case EvilEngine.Api.get_process_by_model_id(process_model_id) do
      {:ok, process} -> fun.(process)
      :not_found -> {:error, :process_not_found}
    end
  end

  defp build_decisions_namespace(identity, plugin_name) do
    %EngineFacade.Decisions{
      list: fn -> EvilEngine.Api.list_decision_definitions() end,
      get: &EvilEngine.Api.get_decision_by_model_id/1,
      get_latest_version: fn model_id ->
        with_decision(model_id, fn definition ->
          EvilEngine.Api.get_latest_decision_version(definition.id)
        end)
      end,
      validate: &EvilEngine.Api.validate_dmn/1,
      deploy: fn sources ->
        parse_and_deploy_dmn(sources, identity, plugin_name)
      end,
      evaluate: fn model_id, input_context, opts ->
        with_decision(model_id, fn definition ->
          EvilEngine.Api.evaluate_decision(
            definition.decision_definition_id,
            input_context,
            Keyword.put(opts, :source, "plugin:#{plugin_name}")
          )
        end)
      end,
      evaluate_by_version: fn model_id, version_string, input_context, opts ->
        with_decision(model_id, fn _definition ->
          EvilEngine.Api.evaluate_decision_by_version(
            model_id,
            version_string,
            input_context,
            Keyword.put(opts, :source, "plugin:#{plugin_name}")
          )
        end)
      end,
      evaluate_service: fn model_id, service_id, input_context, opts ->
        with_decision(model_id, fn definition ->
          EvilEngine.Api.evaluate_decision_service(
            definition.decision_definition_id,
            service_id,
            input_context,
            Keyword.put(opts, :source, "plugin:#{plugin_name}")
          )
        end)
      end,
      get_versions: fn model_id ->
        with_decision(model_id, fn definition ->
          {:ok, EvilEngine.Api.list_decision_versions_for_definition(definition.id)}
        end)
      end,
      get_xml: fn model_id ->
        with_decision(model_id, fn definition ->
          case EvilEngine.Api.get_latest_decision_version(definition.id) do
            {:ok, version} -> {:ok, version.dmn_xml}
            error -> error
          end
        end)
      end,
      enable: fn model_id ->
        with_decision(model_id, fn definition ->
          EvilEngine.Api.update_decision_enabled(definition, true, identity, skip_claims: true)
        end)
      end,
      disable: fn model_id ->
        with_decision(model_id, fn definition ->
          EvilEngine.Api.update_decision_enabled(definition, false, identity, skip_claims: true)
        end)
      end,
      delete_version: fn model_id, version_string ->
        EvilEngine.Api.delete_decision_version(
          model_id,
          version_string,
          Map.from_struct(identity),
          source: "plugin:#{plugin_name}",
          skip_claims: true
        )
      end,
      undeploy: fn model_id ->
        EvilEngine.Api.undeploy_decision(
          model_id,
          Map.from_struct(identity),
          source: "plugin:#{plugin_name}",
          skip_claims: true
        )
      end
    }
  end

  defp with_decision(decision_model_id, fun) do
    case EvilEngine.Api.get_decision_by_model_id(decision_model_id) do
      {:ok, definition} -> fun.(definition)
      :not_found -> {:error, :decision_not_found}
    end
  end

  defp build_process_instances_namespace(identity) do
    %EngineFacade.ProcessInstances{
      get: &EvilEngine.Api.get_process_instance/1,
      abort: fn id, reason ->
        EvilEngine.Api.abort_process_instance(id, reason, identity, skip_claims: true)
      end,
      retry: fn id, opts ->
        EvilEngine.Api.retry_process_instance(id, opts, identity, skip_claims: true)
      end,
      delete: fn id ->
        EvilEngine.Api.delete_process_instance(id, identity, skip_claims: true)
      end
    }
  end

  defp build_user_tasks_namespace do
    %EngineFacade.UserTasks{
      finish: fn fni_id, result, user_identity ->
        EvilEngine.Api.finish_user_task(fni_id, result, user_identity, skip_claims: true)
      end,
      cancel: fn fni_id, reason, user_identity ->
        EvilEngine.Api.cancel_user_task(fni_id, reason, user_identity, skip_claims: true)
      end
    }
  end

  defp build_service_tasks_namespace do
    %EngineFacade.ServiceTasks{
      finish_async: fn fni_id, result ->
        EvilEngine.Api.finish_async_service_task(fni_id, result)
      end,
      fail_async: fn fni_id, error_code, error_message ->
        EvilEngine.Api.fail_async_service_task(fni_id, error_code, error_message)
      end
    }
  end

  defp build_flow_node_instances_namespace do
    %EngineFacade.FlowNodeInstances{
      get: &EvilEngine.Api.get_flow_node_instance/1,
      list_for_process_instance: &EvilEngine.Api.list_flow_node_instances_for_process/1
    }
  end

  defp build_data_objects_namespace do
    %EngineFacade.DataObjects{
      get: &EvilEngine.Api.get_data_object_value/1,
      list_for_instance: &EvilEngine.Api.list_data_object_values/1,
      history_for_instance: &EvilEngine.Api.list_data_object_history/1
    }
  end

  defp build_messages_namespace(plugin_name) do
    plugin_identity = plugin_identity(plugin_name)

    %EngineFacade.Messages{
      publish: fn message_name, correlation_value, payload ->
        alias EvilEngine.Execution.PayloadCap

        case PayloadCap.check(payload, field: :message_payload) do
          :ok ->
            EvilEngine.Api.publish_message(
              message_name,
              payload,
              correlation_value,
              plugin_identity,
              skip_claims: true
            )

          {:error, :payload_too_large, details} ->
            {:error, :payload_too_large, details}
        end
      end
    }
  end

  defp build_signals_namespace(plugin_name) do
    plugin_identity = plugin_identity(plugin_name)

    %EngineFacade.Signals{
      publish: fn signal_name ->
        EvilEngine.Api.publish_signal(signal_name, plugin_identity, skip_claims: true)
      end
    }
  end

  defp build_adhoc_subprocesses_namespace(identity) do
    %EngineFacade.AdhocSubprocesses{
      get_enabled_activities: fn process_instance_id ->
        EvilEngine.Api.get_adhoc_enabled_activities(
          process_instance_id,
          identity,
          skip_claims: true
        )
      end,
      activate_activity: fn process_instance_id, flow_node_id ->
        EvilEngine.Api.activate_adhoc_activity(
          process_instance_id,
          flow_node_id,
          identity,
          skip_claims: true
        )
      end,
      complete: fn process_instance_id ->
        EvilEngine.Api.complete_adhoc_subprocess(
          process_instance_id,
          identity,
          skip_claims: true
        )
      end,
      get_status: fn process_instance_id ->
        EvilEngine.Api.get_adhoc_status(
          process_instance_id,
          identity,
          skip_claims: true
        )
      end
    }
  end

  defp build_timers_namespace(identity) do
    %EngineFacade.Timers{
      trigger_event: fn flow_node_instance_id ->
        EvilEngine.Api.trigger_timer_event(flow_node_instance_id, identity, skip_claims: true)
      end,
      list_schedules: fn filter_opts ->
        EvilEngine.Api.list_timer_schedules(
          identity,
          Keyword.merge(filter_opts, skip_claims: true)
        )
      end,
      get_schedule: fn schedule_id ->
        EvilEngine.Api.get_timer_schedule(schedule_id, identity, skip_claims: true)
      end,
      enable_schedule: fn schedule_id ->
        EvilEngine.Api.enable_timer_schedule(schedule_id, identity, skip_claims: true)
      end,
      disable_schedule: fn schedule_id ->
        EvilEngine.Api.disable_timer_schedule(schedule_id, identity, skip_claims: true)
      end
    }
  end

  defp build_graphql_namespace(identity) do
    %EngineFacade.Graphql{
      query: fn query_string, variables ->
        execute_graphql(query_string, variables, identity)
      end
    }
  end

  defp execute_graphql(query_string, variables, identity) do
    schema = Application.get_env(:peripheral_plugins, :graphql_schema)

    if schema do
      Absinthe.run(query_string, schema,
        variables: variables,
        context: %{actor: identity}
      )
    else
      {:error, :graphql_not_configured}
    end
  end

  defp parse_and_deploy_dmn(sources, identity, plugin_name) do
    parsed_results =
      sources
      |> Enum.with_index(1)
      |> Enum.reduce_while({:ok, []}, fn {xml, index}, {:ok, accumulated} ->
        case EvilEngine.DMN.parse_and_validate(xml) do
          {:ok, definitions} ->
            version_hash =
              :crypto.hash(:sha256, definitions.raw_xml)
              |> Base.encode16(case: :lower)
              |> binary_part(0, 12)

            entry = %{
              decision_definition_id: definitions.id,
              name: definitions.name,
              version: version_hash,
              definitions: definitions,
              xml: xml
            }

            {:cont, {:ok, [entry | accumulated]}}

          {:error, code, metadata} ->
            {:halt,
             {:error, {:dmn_parse_error, %{source_index: index, code: code, metadata: metadata}}}}
        end
      end)

    case parsed_results do
      {:ok, entries} ->
        EvilEngine.Api.deploy_dmn_batch(
          Enum.reverse(entries),
          Map.from_struct(identity),
          source: "plugin:#{plugin_name}",
          skip_claims: true
        )

      {:error, _reason} = error ->
        error
    end
  end

  defp do_register(plugin_name, cap_type, descriptor) do
    case Registry.register_capability(plugin_name, cap_type, descriptor) do
      :ok ->
        :ok

      {:error, :conflict, incumbent} ->
        Logger.warning(
          "Plugin #{plugin_name}: #{cap_type} registration rejected — " <>
            "conflicts with #{incumbent}"
        )

        {:error, :conflict, incumbent}

      {:error, reason, message} ->
        Logger.warning("Plugin #{plugin_name}: #{cap_type} registration rejected — #{message}")

        {:error, reason, message}
    end
  end

  defp engine_id do
    Application.get_env(:peripheral_telemetry, :engine_id, "unknown")
  end

  defp engine_name do
    Application.get_env(:peripheral_telemetry, :engine_name, "unknown")
  end

  defp engine_version do
    Application.spec(:peripheral_plugins, :vsn) |> to_string()
  end
end
