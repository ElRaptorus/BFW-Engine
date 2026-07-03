defmodule EvilEngine.Execution.ProcessInstance.State do
  @moduledoc """
  Internal `:gen_statem` data struct for a `ProcessInstance`.

  Tracks everything the PI needs at runtime: identifiers, the parsed
  BPMN model, active FNI states, and the Task.Supervisor used to
  spawn FNI workers.
  """

  alias EvilEngine.BPMN.Model.Definitions
  alias EvilEngine.BPMN.Model.FlowNode
  alias EvilEngine.BPMN.Model.Process, as: BpmnProcess
  alias EvilEngine.Types.Identity

  @type flow_node_instance_entry :: %{
          pid: pid() | nil,
          flow_node_id: String.t(),
          flow_node_type: atom(),
          event_type: String.t() | nil,
          state: :active | :waiting | :finished | :fatal | :aborted | :interrupted | :error,
          token: EvilEngine.Types.Token.t(),
          previous_flow_node_instance_ids: [String.t()],
          type_properties: map(),
          next_flow_node_ids: [String.t()]
        }

  @type escalation_info :: %{
          optional(:escalation_code) => String.t() | nil,
          optional(:escalation_name) => String.t() | nil
        }

  @type join_routing_entry :: %{
          required(:fni_id) => String.t(),
          required(:gateway_type) => :parallel_gateway | :inclusive_gateway | :complex_gateway,
          required(:required) => pos_integer(),
          required(:arrived_via_flow_ids) => MapSet.t(String.t()),
          optional(:activation_condition) => String.t() | nil,
          optional(:merged_payload) => map(),
          optional(:fired) => boolean()
        }

  @type conditional_waiter_entry :: %{
          flow_node_id: String.t(),
          flow_node: FlowNode.t(),
          handler_module: module(),
          position: :intermediate_catch | :boundary,
          cancel_activity: boolean() | nil,
          host_fni_id: String.t() | nil,
          token_payload: map(),
          fired: boolean()
        }

  @type t :: %__MODULE__{
          process_instance_id: String.t(),
          process_version_id: String.t(),
          process_model: BpmnProcess.t() | nil,
          definitions: Definitions.t() | nil,
          identity: Identity.t() | nil,
          started_at: DateTime.t() | nil,
          started_with_context: map() | nil,
          business_key: String.t() | nil,
          parent_process_instance_id: String.t() | nil,
          root_process_instance_id: String.t() | nil,
          triggerer_flow_node_instance_id: String.t() | nil,
          notify_pid: pid() | nil,
          flow_node_instance_states: %{String.t() => flow_node_instance_entry()},
          data_object_cache: %{String.t() => term()},
          join_routing: %{String.t() => join_routing_entry()},
          conditional_waiters: %{String.t() => conditional_waiter_entry()},
          event_subprocess_triggers: %{String.t() => EvilEngine.Execution.EventSubprocessTrigger.t()},
          event_subprocess_kinds: %{String.t() => {atom(), boolean()}},
          task_supervisor: pid() | nil,
          bpmn_error_info: map() | nil,
          escalation_info: escalation_info() | nil
        }

  @enforce_keys [:process_instance_id, :process_version_id]
  defstruct [
    :process_instance_id,
    :process_version_id,
    :process_model,
    :definitions,
    :identity,
    :started_at,
    :started_with_context,
    :business_key,
    :parent_process_instance_id,
    :root_process_instance_id,
    :triggerer_flow_node_instance_id,
    :notify_pid,
    flow_node_instance_states: %{},
    data_object_cache: %{},
    join_routing: %{},
    conditional_waiters: %{},
    event_subprocess_triggers: %{},
    event_subprocess_kinds: %{},
    task_supervisor: nil,
    bpmn_error_info: nil,
    escalation_info: nil
  ]
end
