defmodule EvilEngine.Execution.HandlerContext do
  @moduledoc """
  Runtime context passed to `FlowNodeHandler.handle_enter/3`.

  Carries the FNI identity (`flow_node_instance_id`), the parsed BPMN process model
  (`process_model`), the standard FEEL bindings (`identity`, `process`,
  `processInstance`, `dataObjects`, `context`), and the `process_instance_id` so
  handlers can locate the PI for async completion.

  Handlers use `process_model` to resolve outgoing sequence flows
  (via `SequenceFlowResolver` for non-gateways, or directly for
  gateway-specific routing logic).

  Async Service Task handlers use `flow_node_instance_id` to later call
  `facade.finish_async_service_task.(flow_node_instance_id, result)` via the
  `EngineFacade` they received during `on_load/1`.

  ## FEEL binding assembly

  `identity`, `process`, `process_instance`, and `data_objects` are stored
  with their **original atom keys** so that other runtime code (e.g.
  `CallActivity`) can pattern-match on them. The conversion to string-keyed
  maps required by the FEEL NIF happens in
  `EvilEngine.Expressions.Context.from_handler_context/2`.

  `context` stores the immutable process-level variables from the start
  request (`started_with_context`). It is already string-keyed because it
  originates from the JSON start payload.

  `host_flow_node_instance_id` is populated only for subscription-model
  boundary event FNIs. It identifies the host activity FNI that this
  boundary event is attached to, enabling the handler to track its
  relationship to the host for cleanup and the PI to manage
  host-boundary lifecycle (interruption, sibling cancellation).
  """

  @type t :: %__MODULE__{
          flow_node_instance_id: String.t(),
          process_instance_id: String.t(),
          root_process_instance_id: String.t() | nil,
          process_version_id: String.t() | nil,
          process_instance_pid: pid() | nil,
          process_model: struct() | nil,
          definitions: struct() | nil,
          flow_node_this: map(),
          context: map(),
          identity: map(),
          process: map(),
          process_instance: map(),
          data_objects: map(),
          loop: map() | nil,
          multi_instance_id: String.t() | nil,
          iteration_index: non_neg_integer() | nil,
          host_flow_node_instance_id: String.t() | nil,
          join_metadata: map() | nil
        }

  defstruct flow_node_instance_id: nil,
            process_instance_id: nil,
            root_process_instance_id: nil,
            process_version_id: nil,
            process_instance_pid: nil,
            process_model: nil,
            definitions: nil,
            flow_node_this: %{},
            context: %{},
            identity: %{},
            process: %{},
            process_instance: %{},
            data_objects: %{},
            loop: nil,
            multi_instance_id: nil,
            iteration_index: nil,
            host_flow_node_instance_id: nil,
            join_metadata: nil
end
