defmodule BfwEngine.Plugins.FacadeBuilder do
  @moduledoc """
  Builds the `BfwEngine.EngineFacade` a plugin receives when the loader starts it.
  """

  alias BfwEngine.EngineFacade
  alias BfwEngine.Events.EngineEventBus
  alias BfwEngine.Plugins.Registry
  alias BfwEngine.Types.Identity

  require Logger

  @spec build(String.t()) :: EngineFacade.t()
  def build(plugin_name) do
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
      register_rest_api_extension: fn prefix, handler ->
        do_register(plugin_name, :rest_api_extension, %{prefix: prefix, module: handler})
      end,
      register_auth_provider: fn handler ->
        case do_register(plugin_name, :auth_provider, %{module: handler}) do
          :ok ->
            auth_registry = Application.get_env(:engine_plugins, :auth_provider_registry)

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
      get_config: &Application.get_env(:engine_plugins, &1),
      processes: build_processes_namespace(identity),
      process_instances: build_process_instances_namespace(identity),
      user_tasks: build_user_tasks_namespace(),
      manual_tasks: build_manual_tasks_namespace(),
      service_tasks: build_service_tasks_namespace(),
      flow_node_instances: build_flow_node_instances_namespace(),
      data_objects: build_data_objects_namespace(),
      decisions: build_decisions_namespace(identity, plugin_name),
      messages: build_messages_namespace(plugin_name),
      signals: build_signals_namespace(plugin_name),
      escalations: build_escalations_namespace(plugin_name),
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
      list: fn -> BfwEngine.Api.list_processes() end,
      get: &BfwEngine.Api.get_process_by_model_id/1,
      get_latest_version: &resolve_latest_version/1,
      deploy: fn sources ->
        BfwEngine.Api.persist_deploy_batch(
          sources,
          identity,
          source: plugin_source,
          skip_claims: true
        )
      end,
      enable: fn model_id ->
        with_process(
          model_id,
          &BfwEngine.Api.update_process_enabled(&1, true,
            identity: identity,
            source: plugin_source,
            skip_claims: true
          )
        )
      end,
      disable: fn model_id ->
        with_process(
          model_id,
          &BfwEngine.Api.update_process_enabled(&1, false,
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
        BfwEngine.Api.undeploy_process(model_id, identity,
          skip_claims: true,
          source: plugin_source
        )
      end,
      start: fn start_opts ->
        BfwEngine.Api.start_process_instance(start_opts, identity, skip_claims: true)
      end
    }
  end

  defp resolve_latest_version(process_model_id) do
    with_process(process_model_id, fn process ->
      BfwEngine.Api.get_latest_process_version(process.id)
    end)
  end

  defp do_delete_version(process_model_id, version_string, identity, source) do
    BfwEngine.Api.delete_process_version(
      process_model_id,
      version_string,
      identity,
      skip_claims: true,
      source: source
    )
  end

  defp with_process(process_model_id, fun) do
    case BfwEngine.Api.get_process_by_model_id(process_model_id) do
      {:ok, process} -> fun.(process)
      :not_found -> {:error, :process_not_found}
    end
  end

  defp build_decisions_namespace(identity, plugin_name) do
    %EngineFacade.Decisions{
      list: fn -> BfwEngine.Api.list_decision_definitions() end,
      get: &BfwEngine.Api.get_decision_by_model_id/1,
      get_latest_version: fn model_id ->
        with_decision(model_id, fn definition ->
          BfwEngine.Api.get_latest_decision_version(definition.id)
        end)
      end,
      validate: &BfwEngine.Api.validate_dmn/1,
      deploy: fn sources ->
        parse_and_deploy_dmn(sources, identity, plugin_name)
      end,
      evaluate: fn model_id, input_context, opts ->
        with_decision(model_id, fn definition ->
          BfwEngine.Api.evaluate_decision(
            definition.decision_definition_id,
            input_context,
            Keyword.put(opts, :source, "plugin:#{plugin_name}")
          )
        end)
      end,
      evaluate_by_version: fn model_id, version_string, input_context, opts ->
        with_decision(model_id, fn _definition ->
          BfwEngine.Api.evaluate_decision_by_version(
            model_id,
            version_string,
            input_context,
            Keyword.put(opts, :source, "plugin:#{plugin_name}")
          )
        end)
      end,
      evaluate_service: fn model_id, service_id, input_context, opts ->
        with_decision(model_id, fn definition ->
          BfwEngine.Api.evaluate_decision_service(
            definition.decision_definition_id,
            service_id,
            input_context,
            Keyword.put(opts, :source, "plugin:#{plugin_name}")
          )
        end)
      end,
      get_versions: fn model_id ->
        with_decision(model_id, fn definition ->
          {:ok, BfwEngine.Api.list_decision_versions_for_definition(definition.id)}
        end)
      end,
      get_xml: fn model_id ->
        with_decision(model_id, fn definition ->
          case BfwEngine.Api.get_latest_decision_version(definition.id) do
            {:ok, version} -> {:ok, version.dmn_xml}
            error -> error
          end
        end)
      end,
      enable: fn model_id ->
        with_decision(model_id, fn definition ->
          BfwEngine.Api.update_decision_enabled(definition, true, identity, skip_claims: true)
        end)
      end,
      disable: fn model_id ->
        with_decision(model_id, fn definition ->
          BfwEngine.Api.update_decision_enabled(definition, false, identity, skip_claims: true)
        end)
      end,
      delete_version: fn model_id, version_string ->
        BfwEngine.Api.delete_decision_version(
          model_id,
          version_string,
          Map.from_struct(identity),
          source: "plugin:#{plugin_name}",
          skip_claims: true
        )
      end,
      undeploy: fn model_id ->
        BfwEngine.Api.undeploy_decision(
          model_id,
          Map.from_struct(identity),
          source: "plugin:#{plugin_name}",
          skip_claims: true
        )
      end
    }
  end

  defp with_decision(decision_model_id, fun) do
    case BfwEngine.Api.get_decision_by_model_id(decision_model_id) do
      {:ok, definition} -> fun.(definition)
      :not_found -> {:error, :decision_not_found}
    end
  end

  defp build_process_instances_namespace(identity) do
    %EngineFacade.ProcessInstances{
      get: &BfwEngine.Api.get_process_instance/1,
      abort: fn id, reason ->
        BfwEngine.Api.abort_process_instance(id, reason, identity, skip_claims: true)
      end,
      retry: fn id, opts ->
        BfwEngine.Api.retry_process_instance(id, opts, identity, skip_claims: true)
      end,
      delete: fn id ->
        BfwEngine.Api.delete_process_instance(id, identity, skip_claims: true)
      end
    }
  end

  defp build_user_tasks_namespace do
    %EngineFacade.UserTasks{
      finish: fn flow_node_instance_id, values, action_id, user_identity ->
        BfwEngine.Api.finish_user_task(
          flow_node_instance_id,
          values,
          user_identity,
          action_id: action_id,
          skip_claims: true
        )
      end,
      cancel: fn flow_node_instance_id, reason, user_identity ->
        BfwEngine.Api.cancel_user_task(flow_node_instance_id, reason, user_identity,
          skip_claims: true
        )
      end
    }
  end

  defp build_manual_tasks_namespace do
    %EngineFacade.ManualTasks{
      confirm: fn flow_node_instance_id, user_identity ->
        BfwEngine.Api.confirm_manual_task(flow_node_instance_id, user_identity, skip_claims: true)
      end,
      cancel: fn flow_node_instance_id, reason, user_identity ->
        BfwEngine.Api.cancel_manual_task(
          flow_node_instance_id,
          reason,
          user_identity,
          skip_claims: true
        )
      end
    }
  end

  defp build_service_tasks_namespace do
    %EngineFacade.ServiceTasks{
      finish_async: fn flow_node_instance_id, result ->
        BfwEngine.Api.finish_async_service_task(flow_node_instance_id, result)
      end,
      fail_async: fn flow_node_instance_id, error_code, error_message ->
        BfwEngine.Api.fail_async_service_task(flow_node_instance_id, error_code, error_message)
      end,
      list_waiting: &BfwEngine.Api.list_waiting_service_tasks/1
    }
  end

  defp build_flow_node_instances_namespace do
    %EngineFacade.FlowNodeInstances{
      get: &BfwEngine.Api.get_flow_node_instance/1,
      list_for_process_instance: &BfwEngine.Api.list_flow_node_instances_for_process/1
    }
  end

  defp build_data_objects_namespace do
    %EngineFacade.DataObjects{
      get: &BfwEngine.Api.get_data_object_value/1,
      list_for_instance: &BfwEngine.Api.list_data_object_values/1,
      history_for_instance: &BfwEngine.Api.list_data_object_history/1
    }
  end

  defp build_messages_namespace(plugin_name) do
    plugin_identity = plugin_identity(plugin_name)

    %EngineFacade.Messages{
      publish: fn message_name, correlation_value, payload ->
        alias BfwEngine.Execution.PayloadCap

        case PayloadCap.check(payload, field: :message_payload) do
          :ok ->
            BfwEngine.Api.publish_message(
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
        BfwEngine.Api.publish_signal(signal_name, plugin_identity, skip_claims: true)
      end
    }
  end

  defp build_escalations_namespace(plugin_name) do
    plugin_identity = plugin_identity(plugin_name)

    %EngineFacade.Escalations{
      publish: fn escalation_code ->
        BfwEngine.Api.trigger_escalation(escalation_code, plugin_identity, skip_claims: true)
      end
    }
  end

  defp build_adhoc_subprocesses_namespace(identity) do
    %EngineFacade.AdhocSubprocesses{
      get_enabled_activities: fn process_instance_id ->
        BfwEngine.Api.get_adhoc_enabled_activities(
          process_instance_id,
          identity,
          skip_claims: true
        )
      end,
      activate_activity: fn process_instance_id, flow_node_id ->
        BfwEngine.Api.activate_adhoc_activity(
          process_instance_id,
          flow_node_id,
          identity,
          skip_claims: true
        )
      end,
      complete: fn process_instance_id ->
        BfwEngine.Api.complete_adhoc_subprocess(
          process_instance_id,
          identity,
          skip_claims: true
        )
      end,
      get_status: fn process_instance_id ->
        BfwEngine.Api.get_adhoc_status(
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
        BfwEngine.Api.trigger_timer_event(flow_node_instance_id, identity, skip_claims: true)
      end,
      list_schedules: fn filter_opts ->
        BfwEngine.Api.list_timer_schedules(
          identity,
          Keyword.merge(filter_opts, skip_claims: true)
        )
      end,
      get_schedule: fn schedule_id ->
        BfwEngine.Api.get_timer_schedule(schedule_id, identity, skip_claims: true)
      end,
      enable_schedule: fn schedule_id ->
        BfwEngine.Api.enable_timer_schedule(schedule_id, identity, skip_claims: true)
      end,
      disable_schedule: fn schedule_id ->
        BfwEngine.Api.disable_timer_schedule(schedule_id, identity, skip_claims: true)
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
    schema = Application.get_env(:engine_plugins, :graphql_schema)

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
        case BfwEngine.DMN.parse_and_validate(xml) do
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
        BfwEngine.Api.deploy_dmn_batch(
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
    Application.spec(:engine_plugins, :vsn) |> to_string()
  end
end
