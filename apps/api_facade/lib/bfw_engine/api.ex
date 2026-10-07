defmodule BfwEngine.Api do
  @moduledoc """
  The single service-layer facade for Bifrost Forge World Engine.

  Every wire adapter (REST, GraphQL, WebSocket) and every in-BEAM
  plugin converges on this module. Each resource lives in its own module;
  this module delegates to it:

  - `BfwEngine.Api.Processes`
  - `BfwEngine.Api.ProcessInstances`
  - `BfwEngine.Api.Tasks`
  - `BfwEngine.Api.Triggers`
  - `BfwEngine.Api.TimerSchedules`
  - `BfwEngine.Api.AdhocSubprocesses`
  - `BfwEngine.Api.DataObjects`
  - `BfwEngine.Api.Decisions`
  """

  @type forbidden_error :: {:error, :forbidden, map()}

  defdelegate list_processes(opts \\ []), to: BfwEngine.Api.Processes
  defdelegate find_processes_by_model_ids(model_ids), to: BfwEngine.Api.Processes
  defdelegate get_process_by_model_id(model_id), to: BfwEngine.Api.Processes
  defdelegate get_latest_process_version(process_id), to: BfwEngine.Api.Processes
  defdelegate find_process_version_by_key(process_id, version_string), to: BfwEngine.Api.Processes

  defdelegate list_process_versions_for_process(process_id, opts \\ []),
    to: BfwEngine.Api.Processes

  defdelegate find_latest_versions_by_process_ids(process_ids), to: BfwEngine.Api.Processes
  defdelegate create_or_sync_process!(process_model_id, definitions), to: BfwEngine.Api.Processes

  defdelegate update_process_enabled(process, enabled_value, opts \\ []),
    to: BfwEngine.Api.Processes

  defdelegate create_process_version(attrs), to: BfwEngine.Api.Processes

  defdelegate soft_delete_process_version(process_version, identity, opts \\ []),
    to: BfwEngine.Api.Processes

  defdelegate deploy_bpmn(bpmn_entries, deployer, opts \\ []), to: BfwEngine.Api.Processes

  defdelegate persist_deploy_batch(process_versions, deployer, opts \\ []),
    to: BfwEngine.Api.Processes

  defdelegate delete_process_version(model_id, version_string, identity, opts \\ []),
    to: BfwEngine.Api.Processes

  defdelegate undeploy_process(model_id, identity, opts \\ []), to: BfwEngine.Api.Processes

  defdelegate has_active_process_instances?(process_version_id),
    to: BfwEngine.Api.ProcessInstances

  defdelegate any_active_process_instances?(version_ids), to: BfwEngine.Api.ProcessInstances
  defdelegate get_process_instance(process_instance_id), to: BfwEngine.Api.ProcessInstances
  defdelegate get_flow_node_instance(flow_node_instance_id), to: BfwEngine.Api.ProcessInstances

  defdelegate list_flow_node_instances_for_process(process_instance_id),
    to: BfwEngine.Api.ProcessInstances

  defdelegate check_lane_access(process_instance_id, lane_names),
    to: BfwEngine.Api.ProcessInstances

  defdelegate soft_delete_process_instance_with_fnis(process_instance, identity),
    to: BfwEngine.Api.ProcessInstances

  defdelegate start_process_instance(opts, identity \\ nil, api_opts \\ []),
    to: BfwEngine.Api.ProcessInstances

  defdelegate abort_process_instance(process_instance_id, reason, identity, opts \\ []),
    to: BfwEngine.Api.ProcessInstances

  defdelegate delete_process_instance(process_instance_id, identity, opts \\ []),
    to: BfwEngine.Api.ProcessInstances

  defdelegate retry_process_instance(process_instance_id, retry_opts, identity, opts \\ []),
    to: BfwEngine.Api.ProcessInstances

  defdelegate lookup_process_instance(process_instance_id), to: BfwEngine.Api.ProcessInstances

  defdelegate list_waiting_service_tasks(implementations), to: BfwEngine.Api.Tasks

  defdelegate finish_user_task(flow_node_instance_id, values, identity, opts \\ []),
    to: BfwEngine.Api.Tasks

  defdelegate cancel_user_task(flow_node_instance_id, reason, identity, opts \\ []),
    to: BfwEngine.Api.Tasks

  defdelegate confirm_manual_task(flow_node_instance_id, identity, opts \\ []),
    to: BfwEngine.Api.Tasks

  defdelegate cancel_manual_task(flow_node_instance_id, reason, identity, opts \\ []),
    to: BfwEngine.Api.Tasks

  defdelegate finish_async_service_task(flow_node_instance_id, result), to: BfwEngine.Api.Tasks

  defdelegate fail_async_service_task(flow_node_instance_id, error_code, error_message),
    to: BfwEngine.Api.Tasks

  defdelegate publish_message(message_name, payload, correlation, identity, opts \\ []),
    to: BfwEngine.Api.Triggers

  defdelegate publish_signal(signal_name, identity, opts \\ []), to: BfwEngine.Api.Triggers

  defdelegate trigger_timer_event(flow_node_instance_id, identity, opts \\ []),
    to: BfwEngine.Api.Triggers

  defdelegate trigger_escalation(escalation_code, identity, opts \\ []),
    to: BfwEngine.Api.Triggers

  defdelegate list_timer_schedules(identity, opts \\ []), to: BfwEngine.Api.TimerSchedules

  defdelegate get_timer_schedule(schedule_id, identity, opts \\ []),
    to: BfwEngine.Api.TimerSchedules

  defdelegate enable_timer_schedule(schedule_id, identity, opts \\ []),
    to: BfwEngine.Api.TimerSchedules

  defdelegate disable_timer_schedule(schedule_id, identity, opts \\ []),
    to: BfwEngine.Api.TimerSchedules

  defdelegate get_adhoc_enabled_activities(process_instance_id, identity, opts \\ []),
    to: BfwEngine.Api.AdhocSubprocesses

  defdelegate activate_adhoc_activity(process_instance_id, flow_node_id, identity, opts \\ []),
    to: BfwEngine.Api.AdhocSubprocesses

  defdelegate complete_adhoc_subprocess(process_instance_id, identity, opts \\ []),
    to: BfwEngine.Api.AdhocSubprocesses

  defdelegate get_adhoc_status(process_instance_id, identity, opts \\ []),
    to: BfwEngine.Api.AdhocSubprocesses

  defdelegate list_data_object_values(process_instance_id, opts \\ []),
    to: BfwEngine.Api.DataObjects

  defdelegate list_data_object_history(process_instance_id, opts \\ []),
    to: BfwEngine.Api.DataObjects

  defdelegate get_data_object_value(id, opts \\ []), to: BfwEngine.Api.DataObjects

  defdelegate validate_dmn(raw_xml), to: BfwEngine.Api.Decisions
  defdelegate deploy_dmn(dmn_entries, deployer, opts \\ []), to: BfwEngine.Api.Decisions

  defdelegate deploy_dmn_batch(decision_versions, deployer, opts \\ []),
    to: BfwEngine.Api.Decisions

  defdelegate evaluate_decision(decision_definition_id, input_context, opts \\ []),
    to: BfwEngine.Api.Decisions

  defdelegate evaluate_decision_by_version(
                decision_definition_id,
                version_string,
                input_context,
                opts \\ []
              ),
              to: BfwEngine.Api.Decisions

  defdelegate evaluate_decision_service(
                decision_definition_id,
                service_id,
                input_context,
                opts \\ []
              ),
              to: BfwEngine.Api.Decisions

  defdelegate list_decision_definitions(opts \\ []), to: BfwEngine.Api.Decisions
  defdelegate get_decision_by_model_id(model_id), to: BfwEngine.Api.Decisions
  defdelegate get_latest_decision_version(definition_id), to: BfwEngine.Api.Decisions

  defdelegate find_decision_version_by_key(definition_id, version_string),
    to: BfwEngine.Api.Decisions

  defdelegate list_decision_versions_for_definition(definition_id, opts \\ []),
    to: BfwEngine.Api.Decisions

  defdelegate update_decision_enabled(definition, enabled_value, identity \\ nil, opts \\ []),
    to: BfwEngine.Api.Decisions

  defdelegate delete_decision_version(model_id, version_string, identity, opts \\ []),
    to: BfwEngine.Api.Decisions

  defdelegate undeploy_decision(model_id, identity, opts \\ []), to: BfwEngine.Api.Decisions

  defdelegate soft_delete_decision_version(decision_version, identity, opts \\ []),
    to: BfwEngine.Api.Decisions

  defdelegate find_latest_decision_versions_by_definition_ids(definition_ids),
    to: BfwEngine.Api.Decisions
end
